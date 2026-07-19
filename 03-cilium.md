# Step 3: CNI プラグイン ③ — Cilium (eBPF データプレーン + Hubble 可視化)

## Cilium とは

Cilium は Linux カーネルの **eBPF (extended Berkeley Packet Filter)** を活用した次世代 CNI です。

- **iptables を使わない** → カーネルネイティブの eBPF プログラムで転送
- **kube-proxy の完全置き換え** (Cilium KubeProxy Replacement)
- **L7 ネットワークポリシー** (HTTP メソッド、パス、gRPC など)
- **Hubble**: eBPF ベースの可観測性プラットフォーム (フロー可視化)

```
┌─────────────────────────────────────────────────────────────┐
│  Cilium eBPF データプレーン                                  │
│                                                              │
│  Pod → veth → TC eBPF hook → (eBPF プログラムで転送判断)    │
│                                                              │
│  ┌──────────────────────────────────────────────────────┐   │
│  │  iptables: (ほぼ) 不使用                             │   │
│  │  kube-proxy: 不使用 (Cilium が Service を処理)       │   │
│  │  eBPF Map: Pod IP ↔ Node IP のマッピングを保持      │   │
│  └──────────────────────────────────────────────────────┘   │
│                                                              │
│  Hubble: eBPF フックでパケットを観測 → フロー可視化         │
└─────────────────────────────────────────────────────────────┘
```

---

## 3.1 前提: CNI が未導入の状態であること

[00-setup.md](00-setup.md) 完了直後、あるいは [02-calico.md](02-calico.md) の
[2.15](02-calico.md#215-calico-のアンインストール-cni-未導入の状態に戻す) を
完了していれば、この状態になっています。

```bash
kubectl get nodes
# 全ノードが NotReady であること (CNI 未導入の証拠)
```

すでに Flannel や Calico が入ったままの場合は、その章のアンインストール手順
(または ホストで `make uninstall`) を先に実行してから始めてください。

---

## 3.2 Helm のインストール

```bash
# ホストで実行
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version
```

---

## 3.3 Cilium のインストール (kube-proxy 置き換えモード)

> **注意**: `kubeadm init` 時に kube-proxy を無効化していない場合、
> Cilium は kube-proxy と共存させるか、`kubeProxyReplacement: true` で置き換えるかを選べます。
> このラボでは kube-proxy 置き換えモードを使います。

```bash
# Cilium CLI のインストール
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all \
  https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz
sudo tar xzvfC cilium-linux-amd64.tar.gz /usr/local/bin
rm cilium-linux-amd64.tar.gz

# Cilium Helm リポジトリ追加
helm repo add cilium https://helm.cilium.io/
helm repo update

# kube-proxy DaemonSet を削除 (置き換えモード使用のため)
kubectl -n kube-system delete daemonset kube-proxy
# kube-proxy の ConfigMap も削除
kubectl -n kube-system delete cm kube-proxy 2>/dev/null || true

# Cilium をインストール
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=192.168.100.11 \
  --set k8sServicePort=6443 \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set ipam.mode=kubernetes \
  --set tunnel=vxlan
```

インストール確認 (3〜5 分待つ):

```bash
# Cilium Pod の状態確認
watch kubectl get pods -n kube-system -l k8s-app=cilium -o wide

# Cilium CLI で確認
cilium status --wait
# ✅ Cilium は全ノードで Ready のはず

kubectl get nodes
# 全ノード Ready であること
```

---

## 3.4 CoreDNS Pod が自動復旧したことを確認

前章 (例えば [2.15](02-calico.md#215-calico-のアンインストール-cni-未導入の状態に戻す))
のアンインストール手順で CoreDNS Pod を削除済みなら `Pending` のまま待っている
はずです。Cilium が Running になった時点で、追加の操作なしに自動的にスケジュ
ールされ、新しい IP が払い出されます。

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
# STATUS が Running になり、IP が新しくなっていることを確認
```

**もし前章のアンインストール手順で削除し忘れていた場合**は、ここで手動削除してください
(前の CNI の古い IP のままだと `CrashLoopBackOff` します):

```bash
kubectl delete pod -n kube-system -l k8s-app=kube-dns
```

---

## 3.5 テスト Pod をデプロイ

`nginx-ds` / `debug` も前章のアンインストール手順 (例: 2.15) で削除済みの前提
です。他の章と同じ manifest (`manifests/nginx-ds.yaml`) を使って作り直します:

```bash
kubectl apply -f manifests/nginx-ds.yaml
kubectl wait --for=condition=Ready pod/debug
```

**もし前章の Pod がまだ残っている場合**は、前の CNI の古い IP を持っているため
**再利用せず必ず削除してから**上記を実行してください:

```bash
kubectl delete -f manifests/nginx-ds.yaml --ignore-not-found
```

---

## 3.6 Pod 間通信の確認 (同一ノード / ノードをまたぐ)

Cilium は Pod 間通信であっても宛先が **同一ノード上の Endpoint** かどうかを
eBPF が判定し、経路をまったく変えます。同一ノードなら送信元 veth (`lxc...`)
から宛先 veth へ直接 redirect し、`cilium_vxlan` (トンネルデバイス) を経由し
ません。ノードをまたぐ場合だけ VXLAN カプセル化が行われます。

### 同一ノード内の Pod 間通信

```bash
DEBUG_NODE=$(kubectl get pod debug -o jsonpath='{.spec.nodeName}')
NGINX_SAME=$(kubectl get pod -l app=nginx-ds -o wide | grep $DEBUG_NODE | awk '{print $6}')
echo "same-node target: $NGINX_SAME (on $DEBUG_NODE)"

kubectl exec debug -- ping -c3 $NGINX_SAME
kubectl exec debug -- wget -qO- $NGINX_SAME
```

`cilium_vxlan` にはパケットが現れないことを確認:

```bash
ssh ubuntu@$DEBUG_NODE 'sudo timeout 5 tcpdump -i cilium_vxlan -n -c3' &
kubectl exec debug -- ping -c3 $NGINX_SAME
wait
# パケット 0 件 = 同一ノード内は VXLAN トンネルを経由しない
```

送信元/宛先それぞれの veth (`lxc...`) に直接 TC eBPF が付いていることを確認:

```bash
ssh ubuntu@$DEBUG_NODE 'ip link show | grep lxc'
# lxcXXXXXX (debug 側) と lxcYYYYYY (同一ノードの nginx 側) がそれぞれ見える

ssh ubuntu@$DEBUG_NODE 'sudo tc filter show dev lxcXXXXXX ingress'
# bpf cil_from_container ...
# ★ 宛先が同一ノードの Endpoint と判定されると、ホストのネットワークスタックを
#   ほぼ経由せず宛先 veth (lxcYYYYYY) へ直接 redirect される
```

### ノードをまたいだ Pod 間通信

```bash
NGINX_W2=$(kubectl get pod -l app=nginx-ds -o wide | grep worker2 | awk '{print $6}')
kubectl exec debug -- ping -c3 $NGINX_W2
kubectl exec debug -- wget -qO- $NGINX_W2
```

物理 NIC で VXLAN カプセル化を確認 (Helm values で `tunnel=vxlan` を指定して
いるため、Flannel と同じ UDP/8472 が使われます):

```bash
ssh ubuntu@$DEBUG_NODE 'sudo tcpdump -i enp1s0 -n udp port 8472 -w /tmp/cilium-vxlan.pcap' &
kubectl exec debug -- wget -qO- $NGINX_W2
ssh ubuntu@$DEBUG_NODE 'sudo pkill tcpdump'

ssh ubuntu@$DEBUG_NODE 'sudo tcpdump -r /tmp/cilium-vxlan.pcap -n -v | head -10'
# 192.168.100.12.xxxx > 192.168.100.13.8472: VXLAN, flags [I] (0x08), vni ...
# IP 10.244.x.x > 10.244.y.y: ...
# 外側: ノード IP + VXLAN、内側: Pod IP (Flannel の 1.6 と同じ構造)
```

**まとめ**: 同一ノード内は eBPF による veth 間の直接 redirect、ノードをまたぐ
場合だけ `cilium_vxlan` 経由の VXLAN カプセル化。この判定はすべて eBPF Map
(`cilium_ipcache` など) 上で行われ、iptables は一切関与しません
(詳細は次の 3.7 で確認します)。

---

## 3.7 eBPF プログラムを観察する

### ロードされている eBPF プログラムを確認

```bash
ssh ubuntu@worker1 'sudo bpftool prog list | grep -E "sched_cls|xdp" | head -20'
# ID: xxx  type: sched_cls  name: cil_from_container  ...
# ID: yyy  type: sched_cls  name: cil_to_container    ...
# ID: zzz  type: xdp        name: cil_xdp_entry        ...
# Cilium が注入した eBPF プログラムの一覧
```

**ポイント**: `sched_cls` は Linux TC (Traffic Control) の hook。
各 Pod の veth インターフェースに `cil_from_container` / `cil_to_container` がアタッチされています。

### eBPF Map (接続テーブル) を見る

```bash
ssh ubuntu@worker1 'sudo bpftool map list | grep cilium | head -10'
# ID: x  name: cilium_ct4_global  type: hash  ...  (接続追跡テーブル)
# ID: y  name: cilium_ipcache     type: hash  ...  (Pod IP → ノード IP マッピング)

# ipcache (Pod IP → ノード IP マッピング) の内容
ssh ubuntu@worker1 'sudo bpftool map dump name cilium_ipcache 2>/dev/null | head -20'
# key: 10.244.0.x/32  value: 192.168.100.11 (control)
# key: 10.244.1.y/32  value: 192.168.100.12 (worker1)
```

**ポイント**: iptables の代わりに eBPF Map でルーティング情報を保持。
Map の検索は O(1) で、iptables の線形スキャンより高速です。

### veth に TC プログラムがアタッチされていることを確認

```bash
# Pod の veth デバイス名を調べる
ssh ubuntu@worker1 'ip link show | grep lxc'
# lxcXXXXXX: <BROADCAST,MULTICAST,UP,LOWER_UP> ...

# TC プログラムの確認
ssh ubuntu@worker1 'sudo tc filter show dev lxcXXXXXX ingress 2>/dev/null'
# filter protocol all pref 1 bpf chain 0
#   bpf cil_from_container [...]
```

---

## 3.8 iptables が(ほぼ)使われていないことを確認

```bash
ssh ubuntu@worker1 'sudo iptables -L -n | wc -l'
# 少ない行数 (kube-proxy 時代は数百〜数千ルールあった)

ssh ubuntu@worker1 'sudo iptables -L KUBE-SERVICES -n 2>/dev/null | wc -l'
# KUBE-SERVICES チェーンが存在しないか空
```

**比較** (参考値):
- kube-proxy + Flannel 時: ~500〜1000 iptables ルール
- Cilium KubeProxy Replacement 時: ~20〜50 ルール (最小限)

---

## 3.9 Service の転送を eBPF で確認

Cilium では kube-proxy の代わりに eBPF が Service の ClusterIP → Pod への転送を担います。

```bash
# ClusterIP で curl (debug Pod から)
CLUSTER_IP=$(kubectl get svc nginx-svc -o jsonpath='{.spec.clusterIP}')
kubectl exec debug -- wget -qO- $CLUSTER_IP

# Cilium の Service エンドポイントを確認
CILIUM_POD=$(kubectl get pod -n kube-system -l k8s-app=cilium -o name | head -1)
kubectl exec -n kube-system $CILIUM_POD -- cilium service list | grep $CLUSTER_IP
# 10.96.x.y:80 nginx-svc/default ClusterIP  1 => 10.244.0.x:80 (active)
#                                                   10.244.1.y:80 (active)
#                                                   10.244.2.z:80 (active)
```

---

## 3.10 Hubble で通信フローを観察する

Hubble は Cilium の可観測性プラットフォームです。eBPF フックを使って全 Pod の通信フローを記録します。

### Hubble CLI のインストール

```bash
# ホストで実行
HUBBLE_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)
curl -L --fail --remote-name-all \
  https://github.com/cilium/hubble/releases/download/$HUBBLE_VERSION/hubble-linux-amd64.tar.gz
sudo tar xzvfC hubble-linux-amd64.tar.gz /usr/local/bin
rm hubble-linux-amd64.tar.gz
```

### Hubble Relay へのポートフォワード

```bash
# 別ターミナルで実行
cilium hubble port-forward &

# Hubble の状態確認
hubble status
# Healthcheck (via localhost:4245): Ok
# Current/Max Flows: ...
# Flows/s: ...
```

### リアルタイムフロー観察

```bash
# 全フローを流す (別ターミナル)
hubble observe --follow

# 別ターミナルで通信を発生させる
NGINX_W2=$(kubectl get pod -l app=nginx-ds -o wide | grep worker2 | awk '{print $6}')
kubectl exec debug -- wget -qO- $NGINX_W2

# Hubble の出力例:
# default/debug       → default/nginx-ds-xxx   to-endpoint   FORWARDED (TCP Flags: SYN)
# default/nginx-ds-xxx → default/debug         to-endpoint   FORWARDED (TCP Flags: SYN, ACK)
```

### Namespace フィルタリング

```bash
hubble observe --namespace default --follow
```

### Hubble UI (Web ダッシュボード)

```bash
# ポートフォワード
kubectl port-forward -n kube-system svc/hubble-ui 12000:80 --address 0.0.0.0 &

# ホスト PC のブラウザで http://<Mini PC IP>:12000 にアクセス
# または Mini PC 上で
xdg-open http://localhost:12000 2>/dev/null || true
```

---

## 3.11 Pod からインターネットへの疎通

Flannel/Calico は iptables の MASQUERADE で SNAT していましたが、Cilium は
kube-proxy 置き換えモードでは **eBPF (BPF Masquerade)** で同じ処理を行います。

```bash
# Pod からインターネットに到達できることを確認
kubectl exec debug -- wget -qO- --timeout=3 http://checkip.amazonaws.com
# ノードの IP (192.168.100.x) が返ってくるはず (Pod IP ではない = SNAT された証拠)
```

### Hubble で外部向けフローを見る

Cilium は外部 (クラスタの Pod/Service ではない宛先) を `reserved:world` という
特別な identity として扱います。Hubble ではこれが可視化されます。

```bash
hubble observe --follow &

kubectl exec debug -- ping -c3 8.8.8.8

# Hubble の出力例:
# default/debug → reserved:world   to-stack   FORWARDED (ICMP)
#                  ^^^^^^^^^^^^^^
#                  クラスタ外向けの通信だと Cilium が識別している
```

### eBPF の NAT テーブルを見る

```bash
# worker1 上で Cilium エージェントの Pod 名を取得
CILIUM_POD_W1=$(kubectl get pod -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=worker1 -o name)

# BPF NAT テーブル (SNAT された接続の一覧)
kubectl exec -n kube-system $CILIUM_POD_W1 -- cilium bpf nat list | grep -i "8.8.8.8\|debug" || \
kubectl exec -n kube-system $CILIUM_POD_W1 -- cilium bpf nat list | head -10
# Pod IP:port → ノード IP:port のマッピングが iptables ではなく eBPF Map 上に存在する
```

### SNAT の瞬間をパケットキャプチャで見る

```bash
ssh ubuntu@worker1 'sudo tcpdump -i enp1s0 -n icmp -c 3' &

kubectl exec debug -- ping -c3 8.8.8.8
# 192.168.100.12 > 8.8.8.8: ICMP echo request
# 送信元がノード IP になっている = iptables ではなく eBPF (TC hook) で書き換え済み
```

**ポイント**: Flannel/Calico は iptables の `nat` テーブルという同じ仕組みの上で
動きますが、Cilium はこの変換も他の Service 処理と同様に eBPF Map 上で完結させる
ため、`iptables -t nat -L` を見ても Cilium の SNAT ルールはほぼ出てきません
(3.8 で確認した通り)。

---

## 3.12 L7 ネットワークポリシーを試す

Cilium の特徴は HTTP メソッドやパスレベルのポリシーです。

```bash
# テスト用 deployment
kubectl apply -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: httpbin
spec:
  replicas: 1
  selector:
    matchLabels:
      app: httpbin
  template:
    metadata:
      labels:
        app: httpbin
    spec:
      containers:
      - name: httpbin
        image: kennethreitz/httpbin
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: httpbin
spec:
  selector:
    app: httpbin
  ports:
  - port: 80
    targetPort: 80
EOF

kubectl wait --for=condition=Available deployment/httpbin
```

**L7 ポリシー: GET /get のみ許可、POST は拒否**:

```bash
kubectl apply -f - <<'EOF'
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: httpbin-l7-policy
spec:
  endpointSelector:
    matchLabels:
      app: httpbin
  ingress:
  - fromEndpoints:
    - matchLabels:
        run: debug
    toPorts:
    - ports:
      - port: "80"
        protocol: TCP
      rules:
        http:
        - method: "GET"
          path: "/get"
EOF

HTTPBIN_IP=$(kubectl get svc httpbin -o jsonpath='{.spec.clusterIP}')

# GET /get は許可
kubectl exec debug -- wget -qO- $HTTPBIN_IP/get | head -5

# POST はブロック (403 Access Denied)
kubectl exec debug -- wget -qO- --post-data='{}' $HTTPBIN_IP/post | head -5
# Access denied

# Hubble で L7 ドロップを観察
hubble observe --type drop --follow &
kubectl exec debug -- wget --post-data='{}' $HTTPBIN_IP/post 2>&1 | tail -3
# default/debug → default/httpbin-xxx  http-request   DROPPED (Policy denied)
```

**ポイント**: Flannel / Calico は L4 (ポート番号) までしか制御できませんが、
Cilium は HTTP メソッドやパスレベルで制御できます。

クリーンアップ:

```bash
kubectl delete ciliumnetworkpolicy httpbin-l7-policy
kubectl delete deployment httpbin
kubectl delete svc httpbin
```

---

## 3.13 Cilium と kube-proxy の比較: ルール数

```bash
# Cilium の Service ルール数
CILIUM_POD=$(kubectl get pod -n kube-system -l k8s-app=cilium -o name | head -1)
kubectl exec -n kube-system $CILIUM_POD -- cilium service list | wc -l

# iptables ルール数 (Cilium モードでは少ない)
ssh ubuntu@worker1 'sudo iptables-save | wc -l'
```

---

## 3.14 Cilium のまとめ

| 項目               | Cilium の動作                                       |
|--------------------|-----------------------------------------------------|
| データプレーン      | eBPF (TC hook / XDP)                               |
| Pod IP 割り当て    | kubernetes IPAM (kubeadm と連携)                    |
| ノード間通信       | VXLAN or Geneve オーバーレイ or Native Routing      |
| ネットワークポリシー | **L3/L4/L7 完全対応** (HTTP, gRPC, Kafka 等)      |
| kube-proxy          | **完全置き換え可能** (eBPF で Service 処理)        |
| 可観測性            | **Hubble** によるフロー可視化                       |
| 特徴               | 高パフォーマンス / 可視性 / 高度なポリシー          |
| 適した用途          | マイクロサービス、セキュリティ重視、可観測性が必要な環境 |

---

## 3.15 Cilium のアンインストール (CNI 未導入の状態に戻す)

**注意**: CoreDNS は `kubectl delete pod` ではなく Deployment の `scale` で扱います。
Pod を消すには kubelet が CNI DEL を呼んでネットワークを片付ける必要があり、それには
CNI 設定がまだ存在している必要があります。先に CNI (手順 3・4) を消してから Pod を削除
しようとすると、kubelet が CNI DEL を完了できず Pod が `Terminating` のまま固まります
(01 章 1.10 と同じ理由)。

```bash
# 1. テスト用リソースを削除 (Cilium の IP を持ったまま残さない)
kubectl delete -f manifests/nginx-ds.yaml --ignore-not-found

# 2. CoreDNS を一時的に 0 replica にする (CNI がまだ生きている今のうちに
#    Pod をきれいに削除させる。ReplicaSet による再作成も防げる)
COREDNS_REPLICAS=$(kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.replicas}')
kubectl scale deployment coredns -n kube-system --replicas=0
kubectl wait --for=delete pod -n kube-system -l k8s-app=kube-dns --timeout=60s

# 3. Cilium 本体を削除
helm uninstall cilium -n kube-system

# 4. 各ノードの Cilium が作ったインターフェースを削除
for node in control worker1 worker2; do
  ssh ubuntu@$node 'sudo ip link delete cilium_vxlan 2>/dev/null; \
    sudo ip link delete cilium_host 2>/dev/null; \
    sudo ip link delete cilium_net 2>/dev/null; true'
done

# 5. CNI 設定ファイルを削除
for node in control worker1 worker2; do
  ssh ubuntu@$node 'sudo rm -f /etc/cni/net.d/*.conf /etc/cni/net.d/*.conflist'
done

# 6. kube-proxy を復元 (3.3 で kubeProxyReplacement のために削除済みのため)
ssh ubuntu@control 'sudo kubeadm init phase addon kube-proxy'

# 7. CoreDNS を元の replica 数に戻す
#    → CNI が存在しない状態で新しい Pod が作られるので Pending のまま待機する
#    ここで戻し忘れると、次章で CNI を入れても CoreDNS の Pod 数が 0 のままになる
kubectl scale deployment coredns -n kube-system --replicas=$COREDNS_REPLICAS
```

`Pending` になっていることを確認:

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
# STATUS: Pending (CNI が無いためスケジュールされない)
```

kube-proxy が復元されたことを確認:

```bash
kubectl get daemonset -n kube-system kube-proxy
```

Node が NotReady に戻ることを確認:

```bash
kubectl get nodes
```

クラスタは [00-setup.md](00-setup.md) 完了直後と同じ CNI 未導入の状態に戻りました。
続けて [01-flannel.md](01-flannel.md) や [02-calico.md](02-calico.md) を、
好きな順番で進められます。3 つとも試したら [04-comparison.md](04-comparison.md)
で比較しましょう。

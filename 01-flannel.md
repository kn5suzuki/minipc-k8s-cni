# Step 1: CNI プラグイン ① — Flannel (VXLAN オーバーレイ)

## Flannel とは

Flannel は最もシンプルな Kubernetes CNI プラグインです。

- **VXLAN オーバーレイ**を使ってノードをまたいだ Pod 間通信を実現
- 各ノードに Pod サブネット (`/24`) を自動割り当て
- **ネットワークポリシーは非対応** (シンプルさを優先)
- CoreOS/Flannel チームが開発。歴史が長く情報が豊富

```
┌─────────────────────────────────────────────────────────────┐
│  worker1 (10.244.1.0/24)         worker2 (10.244.2.0/24)    │
│  ┌──────────┐                    ┌──────────┐               │
│  │  Pod A   │                    │  Pod B   │               │
│  │10.244.1.2│                    │10.244.2.2│               │
│  └────┬─────┘                    └────┬─────┘               │
│       │ veth                          │ veth                │
│  ┌────┴─────┐  VXLAN (UDP/8472)  ┌────┴─────┐               │
│  │  cni0    ├──────────────────►─┤  cni0    │               │
│  │ bridge   │ flannel.1 ↔ enp1s0 │ bridge   │               │
│  └──────────┘                    └──────────┘               │
└─────────────────────────────────────────────────────────────┘
```

---

## 1.1 Flannel のインストール

**前提**: [00-setup.md](00-setup.md) でクラスタが構築済みで、全 Node が `NotReady` であること。

```bash
# control または ホストで実行
kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
```

インストール確認 (2〜3 分待つ):

```bash
watch kubectl get pods -n kube-flannel -o wide
# NAME                    READY   STATUS    NODE
# kube-flannel-ds-xxxxx   1/1     Running   control
# kube-flannel-ds-yyyyy   1/1     Running   worker1
# kube-flannel-ds-zzzzz   1/1     Running   worker2
```

Node が Ready になったことを確認:

```bash
kubectl get nodes
# NAME      STATUS   ROLES           VERSION
# control   Ready    control-plane   v1.31.x
# worker1   Ready    <none>          v1.31.x
# worker2   Ready    <none>          v1.31.x
```

CoreDNS も Running になっていること:

```bash
kubectl get pods -n kube-system | grep coredns
```

---

## 1.2 テスト用 Pod をデプロイ

```bash
# nginx (DaemonSet/Service) と debug Pod をまとめてデプロイ
# manifest は manifests/nginx-ds.yaml を参照。以降の章 (Calico, Cilium) でも同じファイルを使い回します
kubectl apply -f manifests/nginx-ds.yaml
```

Pod が Running になるまで待機:

```bash
kubectl get pods -o wide
# NAME            READY   STATUS    NODE      IP
# nginx-ds-xxx    1/1     Running   control   10.244.0.x
# nginx-ds-yyy    1/1     Running   worker1   10.244.1.x
# nginx-ds-zzz    1/1     Running   worker2   10.244.2.x
# debug           1/1     Running   worker1   10.244.1.y
```

---

## 1.3 同一ノード内の Pod 間通信

ノードをまたぐ通信を見る前に、まず **同じノード上の Pod 同士** が Flannel 環境で
どう通信するかを確認します。ここでは VXLAN の出番がなく、Linux Bridge (`cni0`)
だけで完結することがポイントです。

```bash
# debug Pod と同じノード上の nginx を選ぶ
DEBUG_NODE=$(kubectl get pod debug -o jsonpath='{.spec.nodeName}')
NGINX_SAME=$(kubectl get pod -l app=nginx-ds -o wide | grep $DEBUG_NODE | awk '{print $6}')
echo "same-node target: $NGINX_SAME (on $DEBUG_NODE)"

kubectl exec debug -- ping -c3 $NGINX_SAME
kubectl exec debug -- wget -qO- $NGINX_SAME
```

### ルーティングを確認: flannel.1 を経由しない

```bash
ssh ubuntu@$DEBUG_NODE "ip route get $NGINX_SAME"
# NGINX_SAME dev cni0 src ...
# ★ flannel.1 ではなく cni0 (Linux Bridge) 経由 = 同一ブリッジ内のスイッチング
```

**ポイント**: 宛先が自ノードの Pod サブネット内であれば `cni0` が直接転送します。
VXLAN トンネルは一切関与しません。

### 物理 NIC にはパケットが出ないことを確認

```bash
# 物理 NIC でキャプチャしても同一ノード内の通信は見えないはず
ssh ubuntu@$DEBUG_NODE 'sudo timeout 5 tcpdump -i enp1s0 -n icmp -c3'  &
kubectl exec debug -- ping -c3 $NGINX_SAME
wait
# パケット 0 件 = enp1s0 (物理 NIC) をまったく経由していない証拠
```

### cni0 ブリッジ上ではそのまま見える

```bash
ssh ubuntu@$DEBUG_NODE 'sudo timeout 5 tcpdump -i cni0 -n icmp -c3' &
kubectl exec debug -- ping -c3 $NGINX_SAME
wait
# cni0 上では Pod IP 同士のパケットがカプセル化なしでそのまま見える
```

**まとめ**: 同一ノード内は `cni0` による通常の L2 ブリッジングのみ。
次の 1.4 で確認する「ノードをまたぐ通信」だけが VXLAN カプセル化
(`flannel.1`) を必要とします。

---

## 1.4 ノードをまたいだ Pod 間通信の確認

1.3 とは対照的に、ここでは意図的に **別ノード (worker2)** 上の nginx を選び、
VXLAN オーバーレイ経由の通信を確認します。

```bash
# debug Pod から worker2 の nginx に ping
NGINX_W2=$(kubectl get pod -l app=nginx-ds -o wide | grep worker2 | awk '{print $6}')
kubectl exec debug -- ping -c3 $NGINX_W2

# curl で HTTP レスポンス確認
kubectl exec debug -- wget -qO- $NGINX_W2
```

---

## 1.5 Flannel のネットワーク構造を観察

### VXLAN デバイス (flannel.1) を見る

```bash
ssh ubuntu@worker1 'ip -d link show flannel.1'
# flannel.1: <...> mtu 1450 ...
#     vxlan id 1 local 192.168.100.12 dev enp1s0 srcport 0 0 dstport 8472 nolearning
#     ^^^^^^^^^^^^
#     VNI=1, VXLAN カプセル化, UDP 8472 番ポート使用
```

**ポイント**: `id 1` が VXLAN Network Identifier (VNI)。
Flannel は全クラスタで VNI=1 を使用します。

### FDB (Forwarding Database) を見る

```bash
ssh ubuntu@worker1 'bridge fdb show dev flannel.1'
# xx:xx:xx:xx:xx:xx dst 192.168.100.13 self permanent
# yy:yy:yy:yy:yy:yy dst 192.168.100.11 self permanent
#                   ^^^^^^^^^^^^^^^^^
#                   各ノードの flannel.1 MAC → ノード IP のマッピング
```

**ポイント**: これが VXLAN トンネルの宛先テーブル。
Flannel は etcd/k8s API 経由で各ノードの flannel.1 MAC アドレスとノード IP を共有します。

### ルーティングテーブルを見る

```bash
ssh ubuntu@worker1 'ip route'
# 10.244.0.0/24 via 10.244.0.0 dev flannel.1 onlink   # control の Pod サブネット
# 10.244.1.0/24 dev cni0 proto kernel scope link        # 自分の Pod サブネット (cni0)
# 10.244.2.0/24 via 10.244.2.0 dev flannel.1 onlink   # worker2 の Pod サブネット
```

**ポイント**: 他ノードの Pod サブネットは `flannel.1` 経由でルーティング。
自ノードの Pod サブネットは `cni0` (Linux bridge) 経由。

### Pod の veth pair と cni0 bridge を見る

```bash
ssh ubuntu@worker1 'brctl show cni0'
# bridge name  bridge id          STP  interfaces
# cni0         8000.xxxxxxxxx     no   veth1234abc
#                                      veth5678def

ssh ubuntu@worker1 'ip link show type veth'
# vethXXXX: → Pod の veth もう一方は Pod の netns 内の eth0
```

**ポイント**: Pod ⇄ cni0 ⇄ flannel.1 という経路。
Pod 内の eth0 と cni0 上の veth は一対のトンネル (veth pair)。

### VXLAN カプセル化をキャプチャする

worker1 と worker2 の Pod 間通信を物理 NIC でキャプチャ:

```bash
# ホストの別ターミナルで worker1 にてキャプチャ開始
ssh ubuntu@worker1 'sudo tcpdump -i enp1s0 -n udp port 8472 -w /tmp/flannel.pcap' &

# debug Pod からノードをまたいだ通信
NGINX_W2=$(kubectl get pod -l app=nginx-ds -o wide | grep worker2 | awk '{print $6}')
kubectl exec debug -- wget -qO- $NGINX_W2

# キャプチャ停止 (worker1 で Ctrl+C または)
ssh ubuntu@worker1 'sudo pkill tcpdump'

# パケット確認
ssh ubuntu@worker1 'sudo tcpdump -r /tmp/flannel.pcap -n -v | head -20'
# 192.168.100.12.xxxx > 192.168.100.13.8472: VXLAN, flags [I] (0x08), vni 1
# IP 10.244.1.y > 10.244.2.x: ...
# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
# 外側: ノード IP (192.168.100.x) で VXLAN カプセル化
# 内側: Pod IP (10.244.x.x) が元のパケット
```

### Pod サブネット割り当てを確認

```bash
# 各ノードが持つ Pod サブネット (Node annotation)
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
# control   10.244.0.0/24
# worker1   10.244.1.0/24
# worker2   10.244.2.0/24
```

**ポイント**: kubeadm init で `--pod-network-cidr=10.244.0.0/16` を指定したため、
各ノードに自動で `/24` が配られています。

---

## 1.6 Service の通信経路 (kube-proxy × iptables)

Flannel 環境では kube-proxy が iptables を使って Service の ClusterIP → Pod に転送します。

```bash
# Service の ClusterIP を確認
kubectl get svc nginx-svc
# NAME        TYPE        CLUSTER-IP    PORT(S)
# nginx-svc   ClusterIP   10.96.x.y     80/TCP

CLUSTER_IP=$(kubectl get svc nginx-svc -o jsonpath='{.spec.clusterIP}')

# worker1 の iptables で DNAT ルールを確認
ssh ubuntu@worker1 "sudo iptables -t nat -L KUBE-SERVICES -n | grep $CLUSTER_IP"
# KUBE-SVC-xxx  tcp  -- 0.0.0.0/0  10.96.x.y  tcp dpt:80

# ClusterIP 宛てに curl (debug Pod から)
kubectl exec debug -- wget -qO- $CLUSTER_IP
```

---

## 1.7 Pod からインターネットへの疎通

Pod IP (`10.244.x.x`) はクラスタ外にはルーティングされないプライベートな
アドレスです。それでも Pod から外部と通信できるのは、**ノードが Pod の送信元
IP を自分自身の IP に変換 (SNAT/MASQUERADE) してから外に送り出している**ためです。

```bash
# Pod からインターネット (外部) に到達できることを確認
kubectl exec debug -- wget -qO- --timeout=3 http://checkip.amazonaws.com
# ノードの IP (192.168.100.x) が返ってくるはず (Pod IP ではない = SNAT された証拠)

# Pod 内部のルーティングテーブル (デフォルトゲートウェイは cni0)
kubectl exec debug -- ip route
# default via 10.244.1.1 dev eth0
```

### MASQUERADE ルールを確認する

flanneld はコンテナ起動時に `--ip-masq` オプションを渡されており、Pod サブネット
発でクラスタ外 (`10.244.0.0/16` の外) 宛てのパケットを MASQUERADE する iptables
ルールを自動で追加します。

```bash
ssh ubuntu@worker1 'sudo iptables -t nat -L FLANNEL-POSTRTG -n -v'
# Chain FLANNEL-POSTRTG (1 references)
#  pkts bytes target     prot opt in     out     source               destination
#     0     0 RETURN     all  --  *      *       10.244.1.0/24        10.244.0.0/16    /* flanneld masq */
#     x     x MASQUERADE all  --  *      *       10.244.1.0/24       !224.0.0.0/4       /* flanneld masq */
```

**ポイント**: 宛先がクラスタ内 (`10.244.0.0/16`) の場合は `RETURN` (masquerade
しない = Pod IP のまま Pod 間通信)、それ以外は `MASQUERADE` (ノード IP に変換)
という2段構えになっています。

### SNAT の瞬間をパケットキャプチャで見る

```bash
# worker1 の物理 NIC でキャプチャ (ノードを出る手前)
ssh ubuntu@worker1 'sudo tcpdump -i enp1s0 -n icmp -c 3' &

kubectl exec debug -- ping -c3 8.8.8.8

# 出力例:
# 192.168.100.12 > 8.8.8.8: ICMP echo request
# ^^^^^^^^^^^^^^
# 送信元が Pod IP (10.244.1.y) ではなくノード IP (192.168.100.12) になっている
# = cni0 を出て enp1s0 に到達する前に MASQUERADE で書き換えられている
```

---

## 1.8 Flannel の設定ファイルを確認

```bash
# Flannel の ConfigMap (Pod サブネットの設定)
kubectl get configmap -n kube-flannel kube-flannel-cfg -o yaml
```

---

## 1.9 Flannel のまとめ

| 項目           | Flannel の動作                              |
|----------------|--------------------------------------------|
| データプレーン  | Linux VXLAN (flannel.1 デバイス)           |
| Pod IP 割り当て | ノードごとに /24 を etcd/K8s API から取得  |
| ノード間通信   | VXLAN カプセル化 (UDP/8472)                |
| ネットワークポリシー | **非対応**                            |
| kube-proxy      | iptables モード (変更なし)                 |
| 適した用途      | シンプルさを重視するクラスタ              |

---

## 1.10 Flannel のアンインストール (次の CNI に進む場合)

```bash
# 1. テスト用リソースを削除 (Flannel の IP を持ったまま残さない)
kubectl delete -f manifests/nginx-ds.yaml --ignore-not-found

# 2. Flannel 本体を削除
kubectl delete -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 3. 各ノードの Flannel が作ったインターフェースを削除
for node in control worker1 worker2; do
  ssh ubuntu@$node 'sudo ip link delete flannel.1 2>/dev/null; sudo ip link delete cni0 2>/dev/null; true'
done

# 4. CNI 設定ファイルを削除
for node in control worker1 worker2; do
  ssh ubuntu@$node 'sudo rm -f /etc/cni/net.d/10-flannel.conflist'
done

# 5. CoreDNS Pod を削除 (必ず手順 3・4 の後に行う)
#    → CNI が存在しない状態になるので Pending のまま待機し、
#      02 章で Calico 導入後に自動で新しい IP を取得する (削除は1回で済む)
#    ここを忘れると Flannel 時代の古い IP が残り、Calico 導入後に CrashLoopBackOff する
kubectl delete pod -n kube-system -l k8s-app=kube-dns
```

`Pending` になっていることを確認:

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
# STATUS: Pending (CNI が無いためスケジュールされない)
```

Node が NotReady に戻ることを確認:

```bash
kubectl get nodes
```

[02-calico.md](02-calico.md) に進みます。

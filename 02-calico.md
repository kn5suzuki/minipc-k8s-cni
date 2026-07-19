# Step 2: CNI プラグイン ② — Calico (BGP / IPIP / ネットワークポリシー)

## Calico とは

Calico は本番環境で広く使われる高機能 CNI プラグインです。

- **BGP** でノード間ルートを配布 → L3 ネイティブルーティング (オーバーレイ不要)
- L2 環境では **IPIP** や **VXLAN** でオーバーレイも選択可能
- **ネットワークポリシー** (L3/L4) を完全サポート
- Felix エージェントが各ノードで iptables/eBPF ルールを管理

```
┌─────────────────────────────────────────────────────────────┐
│  BGP モード (同一 L2 セグメント)                                │
│                                                             │
│  worker1 (10.244.A.0/26)         worker2 (10.244.B.0/26)    │
│  ┌──────────┐                    ┌──────────┐               │
│  │  Pod A   │                    │  Pod B   │               │
│  │10.244.A.x│                    │10.244.B.x│               │
│  └────┬─────┘                    └────┬─────┘               │
│       │ veth (cali...)                │ veth (cali...)      │
│       │  BGP route                    │                     │
│  ┌────┴───────────────────────────--──┴─────┐               │
│  │   enp1s0  ←BGP→  enp1s0                  │               │
│  │  (Bird BGP daemon 経由でルート交換)         │               │
│  └───────────────────────────────────────--─┘               │
└─────────────────────────────────────────────────────────────┘
```

**注**: `A`, `B` はノードごとに動的に決まる値です。Flannel (01 章) はノード登録順に
`/24` を連番で割り当てますが、Calico の IPAM は `10.244.0.0/16` プールの中から
`/26` ブロックをほぼランダムに選んで各ノードに割り当てます。そのため
`worker1 = 10.244.1.0/26` のような連番にはならず、`10.244.235.0/26` のような
一見ランダムな値になるのが正常です。実際の割り当ては次で確認できます:

```bash
kubectl get pods -o wide
kubectl get blockaffinities.crd.projectcalico.org -o custom-columns='NODE:.spec.node,CIDR:.spec.cidr'
```

---

## 2.1 前提: CNI が未導入の状態であること

[00-setup.md](00-setup.md) 完了直後、あるいは [01-flannel.md](01-flannel.md) の
[1.10](01-flannel.md#110-flannel-のアンインストール-cni-未導入の状態に戻す) を
完了していれば、この状態になっています。

```bash
kubectl get nodes
# 全ノードが NotReady であること (CNI 未導入の証拠)
```

すでに Flannel や Cilium が入ったままの場合は、その章のアンインストール手順
(または ホストで `make uninstall`) を先に実行してから始めてください。

---

## 2.2 Calico のインストール (Operator 方式)

Calico には大きく2つのインストール方法があります。

| 方式 | やり方 | 設定変更のしかた |
|---|---|---|
| 従来型の manifest 方式 | `calico.yaml` を1枚 `kubectl apply` (01章の Flannel と同じ発想) | ConfigMap を編集して Pod を再作成 |
| **Operator 方式 (本章で採用)** | 小さな operator を先に入れ、`Installation` という CR で設定を渡す | `Installation` を `kubectl patch` するだけで operator が自動反映 |

Calico 公式ドキュメントでも Operator 方式が推奨されているため、本チュートリアルでは
こちらを採用します。手順は次の2段階です:

1. `tigera-operator.yaml` を apply → operator (コントローラ) 自体をインストールするだけ。
   この時点ではまだ Calico のデータプレーン (calico-node など) は何も動かない。
2. `Installation` という CR を apply → ここで初めて具体的な設定 (CIDR やカプセル化方式) を渡す。
   operator がこれを検知して calico-node などを自動的に作成する。

```bash
# 1. Tigera Operator をインストール (まだ Calico 本体は動かない)
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml

# 2. Installation CR を apply (ここで初めて calico-node などが作られる)
kubectl apply -f - <<'EOF'
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - name: default-ipv4-ippool
      cidr: 10.244.0.0/16
      encapsulation: IPIP        # まず IPIP モードで起動
      natOutgoing: Enabled
      nodeSelector: all()
EOF
```

インストール確認 (3〜5 分待つ):

```bash
watch kubectl get pods -n calico-system -o wide
# NAME                        READY   STATUS    NODE
# calico-node-xxxxx           1/1     Running   control
# calico-node-yyyyy           1/1     Running   worker1
# calico-node-zzzzz           1/1     Running   worker2
# calico-kube-controllers-... 1/1     Running   control
```

```bash
kubectl get nodes
# NAME      STATUS   ROLES           VERSION
# control   Ready    control-plane   v1.31.x
# worker1   Ready    <none>          v1.31.x
# worker2   Ready    <none>          v1.31.x
```

---

## 2.3 Calico のコンポーネントを理解する

`calico-system` namespace には役割の異なる複数の Pod が動いています。

| コンポーネント | 種類 | 役割 |
|---|---|---|
| `calico-node` | DaemonSet (全ノードに1つ) | データプレーンの本体。**Felix** (ルート/iptables・eBPFルール programming)、**Bird** (BGPデーモン)、**confd** (datastoreの変更を Bird の設定ファイルに反映) を1コンテナにまとめたもの |
| `calico-typha` | Deployment (既定で2 replica) | Felix と Kubernetes API (datastore) の間に立つキャッシュ用プロキシ |
| `csi-node-driver` | DaemonSet (全ノードに1つ) | Calico の CSI (Container Storage Interface) ドライバ |

### calico-node: Felix / Bird / confd

`calico-node` には2つの initContainer があり、Pod 起動時に1回だけ実行されます:

- `install-cni`: `/etc/cni/net.d/10-calico.conflist` を各ノードに書き込む
  (2.15 のアンインストール手順で最後に削除するファイルの正体)
- `flexvol-driver`: 後述の CSI が使われる前の旧方式のボリュームドライバ (互換性のため残存)

### calico-typha: Felix ↔ API サーバーの中継

Felix は各ノードに1つずつ (このクラスタでは3つ) 存在し、それぞれが Pod/Node/
NetworkPolicy などの変更を Kubernetes API サーバーに `watch` して検知します。
ノード数が数十〜数百に増えると、**Felix の数だけ API サーバーへの watch 接続が
乱立してしまい API サーバーの負荷になります**。Typha はこの watch を1箇所に
集約し、Felix には Typha からまとめて配信することでこの問題を回避します。

```bash
# Felix の設定ログで Typha 経由になっていることを確認
kubectl logs -n calico-system -l k8s-app=calico-node --tail=200 | grep Typha
# TyphaK8sServiceName: calico-typha (from environment variable)

# Felix → calico-typha Service → API サーバー、という経路
kubectl get svc -n calico-system calico-typha
```

**ポイント**: この3ノードのラボ規模では Typha の恩恵はほぼありませんが、Tigera
Operator はデフォルトで常に Typha を挟む構成をとります (可用性のため2 replica)。

### csi-node-driver: なぜ CNI なのに CSI (ストレージ) が出てくるのか

```bash
kubectl get pod -n calico-system -l k8s-app=csi-node-driver \
  -o jsonpath='{.items[0].spec.containers[*].name}{"\n"}'
# calico-csi csi-node-driver-registrar
```

Calico 本体のネットワーク機能とは直接関係なく、**Envoy サイドカーなどが Felix
とやり取りするための Unix Domain Socket を、CSI の Ephemeral Volume 機能を使って
Pod にマウントするため**の仕組みです (Application Layer Policy などのオプション
機能向け)。このチュートリアルではその機能を使っていないため、常駐はしています
が実質的に休眠状態です。「CNI プラグインなのに CSI Driver が動いている」のは
一見不思議ですが、ネットワークとは独立したこのオマケ機能のためだと覚えておけば
十分です。

---

## 2.4 CoreDNS Pod が自動復旧したことを確認

前章 (例えば [1.10](01-flannel.md#110-flannel-のアンインストール-cni-未導入の状態に戻す))
のアンインストール手順で CoreDNS Pod を削除済みなら `Pending` のまま待っている
はずです。Calico が Running になった時点で、追加の操作なしに自動的にスケジュ
ールされ、Calico の IPAM から新しい IP が払い出されます。

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
# NAME                       READY   STATUS    NODE      IP
# coredns-xxxxxxxxxx-xxxxx   1/1     Running   worker1   10.244.x.x   ← Calico の新しい IP
# coredns-xxxxxxxxxx-yyyyy   1/1     Running   worker2   10.244.x.x
```

**もし前章のアンインストール手順で削除し忘れていた場合**は、ここで手動削除してください
(前の CNI の古い IP のままだと `CrashLoopBackOff` します):

```bash
kubectl delete pod -n kube-system -l k8s-app=kube-dns
```

---

## 2.5 テスト用 Pod をデプロイ

`nginx-ds` / `debug` も前章のアンインストール手順 (例: 1.10) で削除済みの前提
です。他の章と同じ manifest (`manifests/nginx-ds.yaml`) を使って作り直します:

```bash
kubectl apply -f manifests/nginx-ds.yaml
```

**もし前章の Pod がまだ残っている場合**は、前の CNI の古い IP を持っているため
**再利用せず必ず削除してから**上記を実行してください:

```bash
kubectl delete -f manifests/nginx-ds.yaml --ignore-not-found
```

---

## 2.6 同一ノード内の Pod 間通信

Calico は Flannel の `cni0` のような共有ブリッジを持たず、Pod ごとに独立した
veth をノードのルーティングテーブルに直接乗せます。**同一ノード内の Pod 間
通信であっても、必ずホストのルーティングテーブルを経由する**という点が
Flannel との大きな違いです。

```bash
# debug Pod と同じノード上の nginx を選ぶ
DEBUG_NODE=$(kubectl get pod debug -o jsonpath='{.spec.nodeName}')
NGINX_SAME=$(kubectl get pod -l app=nginx-ds -o wide | grep $DEBUG_NODE | awk '{print $6}')
echo "same-node target: $NGINX_SAME (on $DEBUG_NODE)"

kubectl exec debug -- ping -c3 $NGINX_SAME
kubectl exec debug -- wget -qO- $NGINX_SAME
```

### ルーティングテーブルで /32 ホストルートを確認

```bash
ssh ubuntu@$DEBUG_NODE "ip route get $NGINX_SAME"
# NGINX_SAME dev cali1234abcd src ...
# ★ 宛先 Pod ごとの /32 ルートが veth (cali...) 個別に張られている

ssh ubuntu@$DEBUG_NODE "ip route | grep cali | grep '/32'"
```

**ポイント**: Flannel の `cni0` は全 Pod の veth を 1 つのブリッジにぶら下げる
L2 スイッチングでしたが、Calico は Felix が Pod ごとに `/32` の個別ルートを
書き込み、**同一ノード内でも Linux のルーティング (L3) で転送**します。

### tunl0 / enp1s0 は経由しないことを確認

```bash
ssh ubuntu@$DEBUG_NODE 'sudo timeout 5 tcpdump -i enp1s0 -n icmp -c3' &
kubectl exec debug -- ping -c3 $NGINX_SAME
wait
# パケット 0 件 = IPIP カプセル化も物理 NIC への送出も発生しない
```

**まとめ**: 同一ノード内は IPIP/BGP どちらの設定でもカプセル化なしの
直接ルーティングのみが行われます。2.7〜2.8 で確認するノードをまたぐ通信
だけが IPIP トンネルや BGP ネイティブルーティングの対象になります。

---

## 2.7 ノードをまたいだ Pod 間通信の確認

2.6 とは対照的に、ここでは意図的に **別ノード (worker2)** 上の nginx を選び、
IPIP/BGP を経由する通信を確認します。

```bash
# debug Pod から worker2 の nginx に ping
NGINX_W2=$(kubectl get pod -l app=nginx-ds -o wide | grep worker2 | awk '{print $6}')
kubectl exec debug -- ping -c3 $NGINX_W2

# curl で HTTP レスポンス確認
kubectl exec debug -- wget -qO- $NGINX_W2
```

---

## 2.8 IPIP モードの動作確認

### IPIP トンネルデバイスを見る

```bash
ssh ubuntu@worker1 'ip -d link show tunl0'
# tunl0: <...> mtu 1480 ...
#     ipip remote any local 192.168.100.12 ttl inherit nopmtudisc
# IPIP トンネル (IP-in-IP カプセル化)

ssh ubuntu@worker1 'ip addr show tunl0'
# inet 10.244.x.y/32 scope global tunl0   ← worker1 自身に割り当てられたブロックの Gateway IP
# Pod サブネットの Gateway IP
```

**ポイント**: Flannel の VXLAN (UDP カプセル化) と異なり、IPIP は IP プロトコル番号 4 でカプセル化します (プロトコルオーバーヘッドが小さい)。

### ルーティングテーブルを見る

```bash
ssh ubuntu@worker1 'ip route | grep tunl0'
# 10.244.A.0/26 via 192.168.100.11 dev tunl0 proto bird  # control のブロック
# 10.244.B.0/26 via 192.168.100.13 dev tunl0 proto bird  # worker2 のブロック
# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
# proto bird = Bird BGP デーモンがインストールしたルート
# A, B は環境ごとに異なる (冒頭の注を参照)。worker1 自身のブロックは
# tunl0 経由ではなくローカルルーティングされるためここには出てこない。
```

**ポイント**: `proto bird` が Calico の BGP デーモン (Bird) がインストールしたルートであることを示します。

### IPIP パケットをキャプチャする

```bash
# worker1 にてキャプチャ
ssh ubuntu@worker1 'sudo tcpdump -i enp1s0 -n proto 4 -w /tmp/calico-ipip.pcap' &

# ノードをまたいだ通信を発生させる
NGINX_W2=$(kubectl get pod -l app=nginx-ds -o wide | grep worker2 | awk '{print $6}')
kubectl exec debug -- wget -qO- $NGINX_W2

ssh ubuntu@worker1 'sudo pkill tcpdump'
ssh ubuntu@worker1 'sudo tcpdump -r /tmp/calico-ipip.pcap -n -v | head -10'
# 192.168.100.12 > 192.168.100.13: IP 10.244.A.x > 10.244.B.y: ...
# 外側: ノード IP, プロトコル 4 (IPIP)
# 内側: Pod IP
```

### BGP ルート広報を確認

```bash
# calico-node Pod に入って BGP ピア状態を確認
CALICO_POD=$(kubectl get pod -n calico-system -l k8s-app=calico-node -o name | head -1)
kubectl exec -n calico-system $CALICO_POD -- birdcl show protocols | grep BGP
# BGP1   BGP      master   up     192.168.100.11   Established
# BGP2   BGP      master   up     192.168.100.13   Established
# 全ノードと BGP ピアが確立していること

# 受信した BGP ルート
kubectl exec -n calico-system $CALICO_POD -- birdcl show route
# 10.244.A.0/26 via 192.168.100.11 on enp1s0 [BGP1 ...] * (100/0) [AS64512i]
# 10.244.B.0/26 via 192.168.100.13 on enp1s0 [BGP2 ...] * (100/0) [AS64512i]
```

---

## 2.9 BGP モード (ネイティブルーティング) に切り替え

同一 L2 セグメントなので、IPIP オーバーレイなしの BGP ネイティブルーティングが可能です。

```bash
kubectl patch installation default --type merge -p '
{
  "spec": {
    "calicoNetwork": {
      "ipPools": [{
        "name": "default-ipv4-ippool",
        "cidr": "10.244.0.0/16",
        "encapsulation": "None",
        "natOutgoing": true,
        "nodeSelector": "all()"
      }]
    }
  }
}'
```

切り替わったことを確認:

```bash
# IPIP トンネルが使われなくなる
ssh ubuntu@worker1 'ip route | grep -v tunl0 | grep 10.244'
# 10.244.A.0/26 via 192.168.100.11 dev enp1s0 proto bird  # enp1s0 直接! (control のブロック)
# 10.244.B.0/26 via 192.168.100.13 dev enp1s0 proto bird  # worker2 のブロック

# カプセル化なしで Pod 間通信できることを確認
kubectl exec debug -- ping -c3 $NGINX_W2

# キャプチャで内側パケットがそのまま流れることを確認
ssh ubuntu@worker1 "sudo tcpdump -i enp1s0 -n 'dst $NGINX_W2' -v -c5"
# Pod IP がそのまま見えるはず (カプセル化されていないので宛先がそのまま Pod IP)
```

**ポイント**: BGP ネイティブルーティングではカプセル化オーバーヘッドがゼロ。
MTU 問題も発生しないためパフォーマンスが向上します。

---

## 2.10 Pod の veth pair を確認

Calico は Flannel の `cni0` bridge と異なり、**veth ペアを直接ルーティング** します。

```bash
ssh ubuntu@worker1 'ip link show type veth'
# cali1234abcd: ...   (Pod ↔ ノードをつなぐ veth)

# ARP proxy が有効 (cali... デバイスで)
ssh ubuntu@worker1 'cat /proc/sys/net/ipv4/conf/cali1234abcd/proxy_arp'
# 1 (有効)

# iptables で Calico が入れたルール確認
ssh ubuntu@worker1 'sudo iptables -L cali-FORWARD -n | head -20'
```

**ポイント**: cni0 bridge を使わず veth の向こう側の Pod に直接ルーティング。
ARP proxy でデフォルトゲートウェイとして振る舞います。

---

## 2.11 ネットワークポリシーを試す

Calico の最大の特徴がネットワークポリシーです。L3/L4 レベルでアクセス制御を実装します。

### シナリオ: frontend のみ backend にアクセス可能にする

```bash
# backend (nginx) を deploy
kubectl run backend --image=nginx:alpine --labels=role=backend --port=80

# frontend (busybox)
kubectl run frontend --image=busybox:latest --labels=role=frontend \
  --restart=Never -- sleep 3600

# attacker (busybox) - frontend でも backend でもない
kubectl run attacker --image=busybox:latest --labels=role=attacker \
  --restart=Never -- sleep 3600

kubectl wait --for=condition=Ready pod/backend pod/frontend pod/attacker
```

ポリシーなしの状態で全員アクセスできることを確認:

```bash
BACKEND_IP=$(kubectl get pod backend -o jsonpath='{.status.podIP}')

kubectl exec frontend -- wget -qO- --timeout=3 $BACKEND_IP && echo "frontend: OK"
kubectl exec attacker -- wget -qO- --timeout=3 $BACKEND_IP && echo "attacker: OK"
```

**ネットワークポリシーを適用** (frontend からのみ backend に到達できるようにする):

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-policy
spec:
  podSelector:
    matchLabels:
      role: backend
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          role: frontend
    ports:
    - protocol: TCP
      port: 80
EOF
```

ポリシー適用後の確認:

```bash
# frontend からはアクセス可能
kubectl exec frontend -- wget -qO- --timeout=3 $BACKEND_IP && echo "frontend: OK"
# 出力: <!DOCTYPE html>... frontend: OK

# attacker からはブロックされる
kubectl exec attacker -- wget -qO- --timeout=3 $BACKEND_IP && echo "attacker: OK" || echo "attacker: BLOCKED"
# 出力: wget: download timed out  attacker: BLOCKED
```

**iptables でブロックルールを確認**:

```bash
BACKEND_NODE=$(kubectl get pod backend -o jsonpath='{.spec.nodeName}')
ssh ubuntu@$BACKEND_NODE \
  'sudo iptables -L cali-pi-default.backend-policy -n | head -20'
# DROP rules で frontend 以外をブロックしていることを確認
```

**ポリシーの削除**:

```bash
kubectl delete networkpolicy backend-policy
kubectl delete pod backend frontend attacker
```

---

## 2.12 Pod からインターネットへの疎通

Calico では IPPool の `natOutgoing` 設定 (2.2 でインストール時に `Enabled` を
指定済み) が、Pod からクラスタ外への通信を SNAT するかどうかを制御します。

```bash
# Pod からインターネットに到達できることを確認
kubectl exec debug -- wget -qO- --timeout=3 http://checkip.amazonaws.com
# ノードの IP (192.168.100.x) が返ってくるはず (Pod IP ではない = SNAT された証拠)
```

### natOutgoing の設定を確認する

```bash
kubectl get ippool default-ipv4-ippool -o jsonpath='{.spec.natOutgoing}{"\n"}'
# true
```

### Felix が入れた MASQUERADE ルールを確認する

Flannel は cni0 という単一のブリッジ単位で ipMasq を掛けますが、Calico は
Felix エージェントが IPPool 全体を1つの ipset にまとめ、そこからの送信元で
IPPool 外向けの通信だけを MASQUERADE します。

```bash
# IPPool のアドレス帯をまとめた ipset
ssh ubuntu@worker1 'sudo ipset list cali40all-ipam-pools | head -10'

# MASQUERADE ルール本体
ssh ubuntu@worker1 'sudo iptables -t nat -L cali-nat-outgoing -n -v'
# MASQUERADE  all  --  *  *  match-set cali40all-ipam-pools src  !match-set cali40all-ipam-pools dst
```

**ポイント**: Flannel の MASQUERADE は cni0 単位の固定ルールですが、Calico は
`natOutgoing` を IPPool ごとに `true`/`false` で切り替えられます。BGP で物理
ネットワークと直接ピアリングし、Pod IP をそのまま外部にルーティングしたい
本番環境では `natOutgoing: false` にして SNAT 自体を無効化することもできます。

### SNAT の瞬間をパケットキャプチャで見る

```bash
ssh ubuntu@worker1 'sudo tcpdump -i enp1s0 -n icmp -c 3' &

kubectl exec debug -- ping -c3 8.8.8.8
# 192.168.100.12 > 8.8.8.8: ICMP echo request
# 送信元がノード IP になっている = enp1s0 に出る前に MASQUERADE で書き換えられている
```

---

## 2.13 calicoctl のインストール (任意)

より詳細な Calico 情報を確認するために `calicoctl` を使えます。

```bash
ssh ubuntu@control
curl -L https://github.com/projectcalico/calico/releases/latest/download/calicoctl-linux-amd64 \
  -o /usr/local/bin/calicoctl
chmod +x /usr/local/bin/calicoctl

# BGP ピア確認
kubectl exec -n calico-system deploy/calico-kube-controllers -- \
  /usr/local/bin/calicoctl node status

# IP Pool 確認
kubectl get ippools.crd.projectcalico.org -o yaml
```

---

## 2.14 Calico のまとめ

| 項目             | Calico の動作                                    |
|------------------|--------------------------------------------------|
| データプレーン    | Linux ルーティング + iptables / eBPF             |
| Pod IP 割り当て  | IPAM プール (BGP で配布)                         |
| ノード間通信     | BGP ネイティブルーティング or IPIP/VXLAN オーバーレイ |
| ネットワークポリシー | **完全対応** (L3/L4, Egress/Ingress)         |
| kube-proxy        | iptables モード (変更なし)                       |
| 特徴              | BGP で物理ネットワークと統合可能                 |
| 適した用途        | 本番環境、物理ネットワーク担当と連携したい場合   |

---

## 2.15 Calico のアンインストール (CNI 未導入の状態に戻す)

```bash
# テスト用リソースを先に削除 (Calico の IP を持ったまま残さない)
kubectl delete -f manifests/nginx-ds.yaml --ignore-not-found

# CoreDNS を一時的に 0 replica にする (CNI がまだ生きている今のうちに
# Pod をきれいに削除させる。ReplicaSet による再作成も防げる)
COREDNS_REPLICAS=$(kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.replicas}')
kubectl scale deployment coredns -n kube-system --replicas=0
kubectl wait --for=delete pod -n kube-system -l k8s-app=kube-dns --timeout=60s

kubectl delete -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml
kubectl delete -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/custom-resources.yaml 2>/dev/null || true

# CRD を削除
kubectl get crds | grep calico | awk '{print $1}' | xargs kubectl delete crd 2>/dev/null || true
kubectl get crds | grep tigera | awk '{print $1}' | xargs kubectl delete crd 2>/dev/null || true

# Namespace 削除
kubectl delete ns calico-system calico-apiserver tigera-operator 2>/dev/null || true

# 各ノードの Calico インターフェースを削除
for node in control worker1 worker2; do
  ssh ubuntu@$node 'sudo ip link delete tunl0 2>/dev/null; \
    for i in $(ip link show type veth | grep cali | awk -F: "{print \$2}"); do \
      sudo ip link delete $i 2>/dev/null; done; true'
done

# CNI 設定を削除
for node in control worker1 worker2; do
  ssh ubuntu@$node 'sudo rm -f /etc/cni/net.d/10-calico.conflist /etc/cni/net.d/calico-kubeconfig'
done

# CoreDNS を元の replica 数に戻す (01章と同じ理由・同じタイミング)
# CNI が存在しない状態で新しい Pod が作られるので Pending のまま次章に進む
kubectl scale deployment coredns -n kube-system --replicas=$COREDNS_REPLICAS

# Node が NotReady になることを確認
kubectl get nodes
```

**⚠️ 重要**: [1.10](01-flannel.md#110-flannel-のアンインストール-cni-未導入の状態に戻す)
と同じ理由で、CoreDNS は Calico のインターフェース/CNI 設定を削除する**前**に 0 replica へ
scale しています。Pod を消すには kubelet が CNI DEL を呼んでネットワークを片付ける必要が
あり、それには CNI 設定がまだ存在している必要があるためです (先に CNI を消してから
`kubectl delete pod` すると `Terminating` のまま固まります)。CNI 削除が終わった**後**に
元の replica 数へ戻すことで、新しい CoreDNS Pod は `Pending` のまま待機し、次にどの CNI
(Flannel や Cilium) を導入した瞬間にも自動的にスケジュールされ、新しい IP を取得します。
ここで scale を戻し忘れると、CoreDNS の Pod 数が 0 のまま次章に進んでしまいます。

クラスタは [00-setup.md](00-setup.md) 完了直後と同じ CNI 未導入の状態に戻りました。
続けて [01-flannel.md](01-flannel.md) や [03-cilium.md](03-cilium.md) を、
好きな順番で進められます。3 つとも試したら [04-comparison.md](04-comparison.md)
で比較しましょう。

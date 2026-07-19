# Step 1: CNI プラグイン ① — Flannel (VXLAN オーバーレイ)

## Flannel とは

Flannel は最もシンプルな Kubernetes CNI プラグインです。

- **VXLAN オーバーレイ**を使ってノードをまたいだ Pod 間通信を実現
- 各ノードに Pod サブネット (`/24`) を自動割り当て
- **ネットワークポリシーは非対応** (シンプルさを優先)
- CoreOS/Flannel チームが開発。歴史が長く情報が豊富

外側の枠が **ノード**、内側の枠が **Pod の netns** を表す。ノードの中では
`netns → veth → cni0 → flannel.1 → enp1s0` の順に接続され、ノードをまたぐ区間
(`enp1s0` の外、両ノードの間) だけが VXLAN でカプセル化される:

```
worker1 (10.244.1.0/24)                  worker2 (10.244.2.0/24)
┌──────────────────────────────┐         ┌──────────────────────────────┐
│    ┌─── Pod A netns ────┐    │         │    ┌─── Pod B netns ────┐    │
│    │  eth0 10.244.1.2   │    │         │    │  eth0 10.244.2.2   │    │
│    └──────────┬─────────┘    │         │    └──────────┬─────────┘    │
│               │ veth         │         │               │ veth         │
│               │              │         │               │              │
│           cni0 (Linux Bridge)│         │           cni0 (Linux Bridge)│
│               │ 10.244.1.1   │         │               │ 10.244.2.1   │
│               │              │         │               │              │
│          flannel.1 (VXLAN)   │         │          flannel.1 (VXLAN)   │
│               │              │         │               │              │
│            enp1s0            │         │            enp1s0            │
└───────────────┴──────────────┘         └───────────────┴──────────────┘
                │ 192.168.100.12                         │ 192.168.100.13
                │                                        │
                └──── VXLAN encapsulation (UDP/8472) ────┘
```

---

## 1.1 Flannel のインストール

**前提**: [00-setup.md](00-setup.md) でクラスタが構築済みで、全 Node が `NotReady` であること
(CNI 未導入の状態)。すでに Calico や Cilium を試した後であれば、その章の
アンインストール手順 (または ホストで `make uninstall`) を先に実行してから
始めてください。

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

## 1.2 Flannel が配置したもの

### kube-flannel-cfg ConfigMap (クラスタ全体の設定)

クラスタに1つだけ存在するこの ConfigMap が、`kube-flannel-ds` が各ノードで何をするかの
元ネタになる:

```bash
kubectl get configmap -n kube-flannel kube-flannel-cfg -o yaml
```

```yaml
data:
  cni-conf.json: |
    {
      "name": "cbr0",
      "plugins": [
        { "type": "flannel", "delegate": { "hairpinMode": true, "isDefaultGateway": true } },
        { "type": "portmap", "capabilities": { "portMappings": true } }
      ]
    }
  net-conf.json: |
    {
      "Network": "10.244.0.0/16",
      "Backend": { "Type": "vxlan" }
    }
```

- `cni-conf.json`: 後述の「CNI 設定ファイル」で見るノードごとの `10-flannel.conflist` の
  クラスタ共通テンプレート。`kube-flannel-ds` が起動時にこれをそのままノードのローカル
  ファイルへコピーする。
- `net-conf.json` の `Network`: クラスタ全体の Pod ネットワーク。`kubeadm init
  --pod-network-cidr` で指定した値と一致している必要がある (不一致だとノードごとの `/24`
  払い出しが壊れる)。
- `net-conf.json` の `Backend.Type`: `"vxlan"`。ここが `"host-gw"` 等に変わると
  `flannel.1` は使われず直接ルーティングになり、本章で見る VXLAN 周りの挙動全体が変わる。

### kube-flannel-ds

`kube-flannel-ds` は各ノードに1台ずつ配置される DaemonSet Pod で、上の ConfigMap を読み込んで
そのノードの CNI プラグインとして動作する。起動時にホスト上へ `flannel.1` VXLAN インターフェース
と CNI 設定ファイル (`/etc/cni/net.d/10-flannel.conflist`) を配置し、Kubernetes API から
全ノードの割り当て済み PodCIDR (`10.244.x.0/24`) を読み取ってルーティングテーブルと VXLAN の
FDB (転送先 MAC/IP) を構築・維持する。この Pod がまだ `Running` になっていない (= ノードに CNI
が導入されていない) 間は、そのノードは `NotReady` のままとなる (1.1 で確認した通り)。

### CNI 設定ファイル (10-flannel.conflist)

kubelet は `/etc/cni/net.d/` 内でファイル名が辞書順で最も早い `*.conflist`/`*.conf` を採用する
(ここでは `10-flannel.conflist` のみなのでそれが使われる)。`kube-flannel-ds` が上の ConfigMap
の `cni-conf.json` をそのままコピーしたものであることを、worker1 に SSH して確認する:

```bash
ssh ubuntu@worker1 'cat /etc/cni/net.d/10-flannel.conflist'
# {
#   "name": "cbr0",
#   "cniVersion": "0.3.1",
#   "plugins": [
#     { "type": "flannel", "delegate": { "hairpinMode": true, "isDefaultGateway": true } },
#     { "type": "portmap", "capabilities": { "portMappings": true } }
#   ]
# }
```

中身は2つの CNI プラグインの chain:

1. **`flannel`**: `kube-flannel-ds` が書き出した `/run/flannel/subnet.env`
   (このノードに割り当てられた `10.244.x.0/24` などが入っている) を読み取り、
   実際の veth 作成やブリッジ接続は `bridge` プラグイン (`cni0`) に委譲する。
2. **`portmap`**: `hostPort` を指定した Pod のポートフォワーディング (iptables DNAT) を担当する。

Pod 間の実際の通信でこれらがどう使われるかは、1.4 で `cni0`/veth を構築したうえで、
1.5 (同一ノード内) と 1.6 (ノードをまたぐ) で確認します。

### flannel.1 (VXLAN インターフェース)

`kube-flannel-ds` が ConfigMap の `net-conf.json` (`Backend.Type: vxlan`) に従って
実際にホスト側へ何を配置したか、worker1 に SSH して確認する:

```bash
ssh ubuntu@worker1 'ip -d link show flannel.1'
# 4: flannel.1: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 ... state UNKNOWN
#     link/ether ...
#     vxlan id 1 local 192.168.100.12 dev enp1s0 srcport 0 0 dstport 8472 \
#       nolearning ttl auto ageing 300 noudpcsum ...
```

- `vxlan id 1`: VXLAN Network Identifier (VNI)。全ノードで固定値 1。
- `local 192.168.100.12 dev enp1s0`: このノードの管理用アドレスを送信元として、
  物理 NIC (`enp1s0`) 経由でカプセル化パケットを送る設定。
- `dstport 8472`: VXLAN の宛先 UDP ポート。IANA 標準の 4789 ではなく Flannel 独自の 8472 を使う。
- `nolearning`: 通常の VXLAN は初回送信時に ARP/送信元 MAC から FDB (宛先 MAC → リモート VTEP IP の対応表)
  を学習するが、Flannel はこれを無効化し、`kube-flannel-ds` が Kubernetes API から得た
  全ノードの情報をもとに FDB エントリを直接プログラムする (1.6 で `bridge fdb show dev flannel.1` を確認する)。

---

## 1.3 テスト用 Pod をデプロイ

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

## 1.4 Flannel が Pod 用に構築したもの

1.2 で見た `flannel.1` や CNI 設定ファイルはノードに CNI が導入された時点で存在するが、
`cni0` Linux Bridge と各 Pod の veth pair は、そのノードに **Pod が1つもスケジュールされて
いない間は存在しない**。conflist の `flannel` プラグインが委譲する `bridge` プラグインは、
最初の Pod (ADD リクエスト) が来て初めて `cni0` を作成するため。1.3 で初めて Pod が
デプロイされたことで、worker1 上にこれらが作られたことを確認する。

### cni0 ブリッジ

```bash
ssh ubuntu@worker1 'ip -d addr show cni0'
# 5: cni0: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 ...
#     link/ether ...
#     inet 10.244.1.1/24 brd 10.244.1.255 scope global cni0
#     bridge ...
```

- `inet 10.244.1.1/24`: このノードの Pod サブネット (`/run/flannel/subnet.env` の
  `FLANNEL_SUBNET`) の先頭アドレス。Pod からのデフォルトゲートウェイになる
  (1.8 で `kubectl exec debug -- ip route` から確認する)。
- `mtu 1450`: VXLAN ヘッダ (50 byte) 分を差し引いた値。物理 NIC の MTU 1500 と揃えるための調整。

### veth pair

```bash
ssh ubuntu@worker1 'brctl show cni0'
# bridge name  bridge id          STP  interfaces
# cni0         8000.xxxxxxxxx     no   veth1234abc
#                                      veth5678def
```

worker1 上の Pod (`nginx-ds`, `debug`) の数だけ veth が `cni0` にぶら下がっている。
`bridge` プラグインが Pod ごとに veth pair を作成し、ホスト側の一端を `cni0` に接続、
コンテナ側の一端を Pod の netns 内に移動させて `eth0` にリネームする:

```bash
ssh ubuntu@worker1 'ip link show type veth'
# vethXXXX@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> ... master cni0
```

### ここまでで構築されたインターフェース構成

1.2 (`flannel.1`) と本節 (`cni0`・veth) を合わせると、worker1 上には次のようなインターフェースの
連なりが出来上がっている:

```
worker1 (192.168.100.12)
┌──────────────────────────────────────────────────────────────┐
│  debug Pod netns         nginx-ds Pod netns                  │
│  ┌─────────────┐         ┌─────────────┐                     │
│  │ eth0        │         │ eth0        │                     │
│  │10.244.1.y/24│         │10.244.1.x/24│                     │
│  └──────┬──────┘         └──────┬──────┘                     │
│         │ veth pair             │ veth pair                  │
│  ┌──────┴───────────────────────┴─--─────┐                   │
│  │        cni0 (Linux Bridge)            │                   │
│  │        10.244.1.1/24, mtu 1450        │                   │
│  └────────────────────┬──────────────────┘                   │
│                       │                                      │
│  ┌────────────────────┴──────────────────┐                   │
│  │ flannel.1 (VXLAN, vni 1, mtu 1450)    │                   │
│  └────────────────────┬-─────────────────┘                   │
│                       │ VXLAN カプセル化                       │
│                       │ (UDP/8472, ノードをまたぐ場合のみ)       │
│  ┌────────────────────┴───────────────────┐                  │
│  │  enp1s0 (物理 NIC, 192.168.100.12)      │                 │
│  └────────────────────────────────────────┘                 │
└─────────────────────────────────────────────────────────────┘
```

**ポイント**: 同一ノード内 (`eth0` → `cni0`) は通常の L2 ブリッジング、
ノードをまたぐ場合のみ `cni0` → `flannel.1` → `enp1s0` という経路で VXLAN カプセル化される。
それぞれ 1.5 (同一ノード内) と 1.6 (ノードをまたぐ) で実際のパケットを見ながら確認する。

---

## 1.5 同一ノード内の Pod 間通信

ノードをまたぐ通信を見る前に、まず **同じノード上の Pod 同士** が Flannel 環境で
どう通信するかを確認します。ここでは VXLAN の出番がなく、Linux Bridge (`cni0`)
だけで完結することがポイントです。

```bash
# debug Pod と同じノード (worker1) 上の nginx を選ぶ
NGINX_W1=$(kubectl get pod -l app=nginx-ds -o wide | grep worker1 | awk '{print $6}')
kubectl exec debug -- ping -c3 $NGINX_W1

# curl で HTTP レスポンス確認
kubectl exec debug -- wget -qO- $NGINX_W1
```

### ルーティングを確認: flannel.1 を経由しない

```bash
ssh ubuntu@worker1 "ip route get $NGINX_W1"
# NGINX_W1 dev cni0 src ...
# ★ flannel.1 ではなく cni0 (Linux Bridge) 経由 = 同一ブリッジ内のスイッチング
```

**ポイント**: 宛先が自ノードの Pod サブネット内であれば `cni0` が直接転送します。
VXLAN トンネルは一切関与しません。

### 物理 NIC にはパケットが出ないことを確認

```bash
# 物理 NIC でキャプチャしても同一ノード内の通信は見えないはず
ssh ubuntu@worker1 'sudo timeout 5 tcpdump -i enp1s0 -n icmp -c3'  &
kubectl exec debug -- ping -c3 $NGINX_W1
wait
# パケット 0 件 = enp1s0 (物理 NIC) をまったく経由していない証拠
```

### cni0 ブリッジ上ではそのまま見える

```bash
ssh ubuntu@worker1 'sudo timeout 5 tcpdump -i cni0 -n icmp -c3' &
kubectl exec debug -- ping -c3 $NGINX_W1
wait
# cni0 上では Pod IP 同士のパケットがカプセル化なしでそのまま見える
```

**まとめ**: 同一ノード内は `cni0` による通常の L2 ブリッジングのみ。
次の 1.6 で確認する「ノードをまたぐ通信」だけが VXLAN カプセル化
(`flannel.1`) を必要とします。

---

## 1.6 ノードをまたいだ Pod 間通信

**別ノード (worker2)** 上の nginx を選び、VXLAN オーバーレイ経由の通信を確認します。以下、1.5 と同じ手順 (ping/wget →
ルーティング確認 → パケットキャプチャ) を辿りながら、結果がどう変わるかを見比べます。

```bash
# debug Pod から worker2 の nginx に ping
NGINX_W2=$(kubectl get pod -l app=nginx-ds -o wide | grep worker2 | awk '{print $6}')
kubectl exec debug -- ping -c3 $NGINX_W2

# curl で HTTP レスポンス確認
kubectl exec debug -- wget -qO- $NGINX_W2
```

### ルーティング

```bash
ssh ubuntu@worker1 "ip route get $NGINX_W2"
# NGINX_W2 dev flannel.1 src ...
# ★ 1.5 の cni0 とは違い、今度は flannel.1 経由 = VXLAN トンネルへ

ssh ubuntu@worker1 'ip route'
# 10.244.0.0/24 via 10.244.0.0 dev flannel.1 onlink   # control の Pod サブネット
# 10.244.1.0/24 dev cni0 proto kernel scope link        # 自分の Pod サブネット (cni0)
# 10.244.2.0/24 via 10.244.2.0 dev flannel.1 onlink   # worker2 の Pod サブネット
```

**ポイント**: 1.5 では宛先が自ノードの Pod サブネットだったため `cni0` 止まりでしたが、
ここでは宛先 (worker2 の `10.244.2.0/24`) が他ノードの Pod サブネットなので `flannel.1`
経由でルーティングされます。VXLAN トンネルが初めて関与します。

### MAC アドレス解決

```bash
ssh ubuntu@worker1 'ip neigh show dev flannel.1'
# 10.244.2.0 dev flannel.1 lladdr yy:yy:yy:yy:yy:yy PERMANENT
```

**ポイント**: `ip route get` が示した nexthop `10.244.2.0` はまだ L3 アドレスです。
フレームを送るには MAC アドレス (L2) への解決が要りますが、Flannel は通常の ARP に頼らず
`kube-flannel-ds` が Kubernetes API 経由でこの近隣キャッシュも静的に (`PERMANENT`)
プログラムします (1.2 で見た `nolearning` と対になる仕組みです)。

### flannel.1 でのエンキャップ

ここまでで宛先 MAC アドレス (`yy:yy:yy:yy:yy:yy`) は分かりましたが、それが VXLAN 的に
どのノード (VTEP) 宛てにカプセル化すべきかはまだ分かりません。それを解決するのが FDB です。

```bash
ssh ubuntu@worker1 'bridge fdb show dev flannel.1'
# xx:xx:xx:xx:xx:xx dst 192.168.100.13 self permanent
# yy:yy:yy:yy:yy:yy dst 192.168.100.11 self permanent
#                   ^^^^^^^^^^^^^^^^^
#                   各ノードの flannel.1 MAC → ノード IP のマッピング
```

**ポイント**: `ip neigh` の MAC アドレス (`yy:yy:yy:yy:yy:yy`) をこの FDB で引くと
`dst 192.168.100.13` (worker2) が見つかります。これでようやく VXLAN カプセル化の宛先
ノード IP が確定します。この FDB も `nolearning` により ARP と同様、`kube-flannel-ds` が
K8s API 経由で直接プログラムします。

### 物理 NIC でキャプチャ: 今度は VXLAN パケットが見える

```bash
# 物理NIC で見えないことを確認した 1.5 とは対照的に、ここではキャプチャに残す
ssh ubuntu@worker1 'sudo tcpdump -i enp1s0 -n udp port 8472 -w /tmp/flannel.pcap' &

kubectl exec debug -- wget -qO- $NGINX_W2

ssh ubuntu@worker1 'sudo pkill tcpdump'

ssh ubuntu@worker1 'sudo tcpdump -r /tmp/flannel.pcap -n -v | head -20'
# 192.168.100.12.xxxx > 192.168.100.13.8472: VXLAN, flags [I] (0x08), vni 1
# IP 10.244.1.y > 10.244.2.x: ...
# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
# 外側: ノード IP (192.168.100.x) で VXLAN カプセル化
# 内側: Pod IP (10.244.x.x) が元のパケット
```

**まとめ**: 1.5 (同一ノード内) は `cni0` の L2 ブリッジングだけで完結し、物理 NIC には
一切パケットが出ませんでした。1.6 (ノードをまたぐ) では `flannel.1` が FDB を参照して
宛先ノードの VTEP (ノード IP) 向けに VXLAN カプセル化し、物理 NIC 上にノード IP 同士の
UDP/8472 パケットとして現れます。

### 参考: Pod サブネット割り当て

```bash
# 各ノードが持つ Pod サブネット (Node annotation)
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.podCIDR}{"\n"}{end}'
# control   10.244.0.0/24
# worker1   10.244.1.0/24
# worker2   10.244.2.0/24
```

**ポイント**: kubeadm init で `--pod-network-cidr=10.244.0.0/16` を指定したため、
各ノードに自動で `/24` が配られています。1.5/1.6 で見た `cni0`/`flannel.1` の
ルーティング先はこの割り当てに基づきます。

---

## 1.7 Service の通信経路 (kube-proxy × iptables)

Flannel 自体は Service を扱わず、ClusterIP → Pod の変換は kube-proxy が iptables で行います。
Flannel が受け持つのは、その変換後の宛先 Pod IP への実際の転送 (1.5/1.6 で見た経路) です。
以下、ClusterIP 宛てのパケットが最終的にどの Pod IP に化けるかを iptables のチェーンを
辿って確認し、そこから先が 1.5/1.6 と同じであることを見ます。

```bash
# Service の ClusterIP を確認
kubectl get svc nginx-svc
# NAME        TYPE        CLUSTER-IP    PORT(S)
# nginx-svc   ClusterIP   10.96.x.y     80/TCP

CLUSTER_IP=$(kubectl get svc nginx-svc -o jsonpath='{.spec.clusterIP}')

# ClusterIP 宛てに curl (debug Pod から)
kubectl exec debug -- wget -qO- $CLUSTER_IP
```

### KUBE-SERVICES: ClusterIP 宛てを検知する

```bash
ssh ubuntu@worker1 "sudo iptables -t nat -L KUBE-SERVICES -n | grep $CLUSTER_IP"
# KUBE-SVC-xxx  tcp  -- 0.0.0.0/0  10.96.x.y  tcp dpt:80
```

**ポイント**: `KUBE-SERVICES` は全 Service 共通の入口チェーン。宛先 IP:port が
ClusterIP:port に一致するパケットを、この Service 専用の `KUBE-SVC-xxx` チェーンへ
`-j` で飛ばします。

### KUBE-SVC-xxx: バックエンド Pod をランダムに選ぶ

```bash
ssh ubuntu@worker1 "sudo iptables -t nat -L KUBE-SVC-xxx -n"
# KUBE-SEP-aaa  all  --  0.0.0.0/0  0.0.0.0/0  statistic mode random probability 0.33333
# KUBE-SEP-bbb  all  --  0.0.0.0/0  0.0.0.0/0  statistic mode random probability 0.50000
# KUBE-SEP-ccc  all  --  0.0.0.0/0  0.0.0.0/0
```

**ポイント**: nginx-ds は DaemonSet なので Endpoints は3つ (各ノード1つずつ)。
`statistic mode random probability` で確率的に1つの `KUBE-SEP-xxx` (Service Endpoint =
Pod 1つに対応) へ振り分けます。1.5/1.6 で同一ノード/別ノードを明示的に選んでいたのに対し、
Service 経由ではどの Pod に転送されるかは毎回ランダムです。

### KUBE-SEP-xxx: 実際の DNAT

```bash
ssh ubuntu@worker1 "sudo iptables -t nat -L KUBE-SEP-aaa -n"
# DNAT  tcp  --  0.0.0.0/0  0.0.0.0/0  tcp to:10.244.1.x:80
```

**まとめ**: `KUBE-SERVICES → KUBE-SVC-xxx → KUBE-SEP-xxx` で ClusterIP:80 が
最終的に特定の Pod IP:80 (例: `10.244.1.x:80`) へ DNAT されます。DNAT が済んだ
時点でパケットは通常の Pod 宛てパケットと同じになるため、そこから先の転送経路は
選ばれた Pod が同一ノードか別ノードかによって 1.5 (`cni0` のみ) か 1.6 (`flannel.1`
経由の VXLAN) のどちらかに合流します。Flannel から見ると Service は関知しない、
kube-proxy が Pod IP を差し替えるだけの前段処理です。

---

## 1.8 Pod からインターネットへの疎通

Pod IP (`10.244.x.x`) はクラスタ外にはルーティングされないプライベートな
アドレスです。それでも Pod から外部と通信できるのは、**ノードが Pod の送信元
IP を自分自身の IP に変換 (SNAT/MASQUERADE) してから外に送り出している**ためです。

ここまでの 1.4〜1.7 で見た `cni0`/`flannel.1` は Pod ネットワーク**内部**の転送を
担うものでしたが、Flannel の役割はそれだけではありません。クラスタ**外**への出口
(egress) の NAT 設定もあわせて自分自身の責務として持っており、`kube-flannel-ds`
(実体は `flanneld`) が各ノード起動時にこの節で見る MASQUERADE ルールを iptables へ
自動で追加します。kube-proxy や Kubernetes 本体はこの設定に一切関与しません。

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

## 1.10 Flannel のアンインストール (CNI 未導入の状態に戻す)

**参考**: 以下の手順 3〜5 (Flannel 本体・各ノードのインターフェース・CNI 設定ファイルの削除) は、
ホスト側で `make uninstall` を実行すれば1コマンドで完了します (`Makefile` の `uninstall`
ターゲットの実体がまさにこの操作です)。ただし `make uninstall` は手順 1 (テスト用リソースの
削除) と手順 2・6 (CoreDNS の scale 操作) はカバーしていません — これらは次章の冒頭でも改めて
必要になった際に手動で対応できるようになっているため、意図的にスコープ外です。学習目的で
一つずつ確認したい場合や、手順 1・2・6 も含めて完全に戻したい場合は、以下を手動で実行してください。

**注意**: CoreDNS Pod は `kubectl delete pod` ではなく、Deployment を一時的に 0 replica に
`scale` することで削除します。Pod を消すには kubelet が CNI DEL を呼んでネットワークを
片付ける必要があり、それには CNI 設定がまだ存在している必要があります。先に CNI (手順 3〜5)
を消してから Pod を削除しようとすると、kubelet が CNI DEL を完了できず Pod が
`Terminating` のまま永遠に固まります。そのため CoreDNS の削除は CNI 削除より**前**に、
再作成 (scale を元に戻す) は CNI 削除より**後**に行います。

```bash
# 1. テスト用リソースを削除 (Flannel の IP を持ったまま残さない)
kubectl delete -f manifests/nginx-ds.yaml --ignore-not-found

# 2. CoreDNS を一時的に 0 replica にする (CNI がまだ生きている今のうちに
#    Pod をきれいに削除させる。ReplicaSet による再作成も防げる)
COREDNS_REPLICAS=$(kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.replicas}')
kubectl scale deployment coredns -n kube-system --replicas=0
kubectl wait --for=delete pod -n kube-system -l k8s-app=kube-dns --timeout=60s

# 3. Flannel 本体を削除
kubectl delete -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml

# 4. 各ノードの Flannel が作ったインターフェースを削除
for node in control worker1 worker2; do
  ssh ubuntu@$node 'sudo ip link delete flannel.1 2>/dev/null; sudo ip link delete cni0 2>/dev/null; true'
done

# 5. CNI 設定ファイルを削除
for node in control worker1 worker2; do
  ssh ubuntu@$node 'sudo rm -f /etc/cni/net.d/10-flannel.conflist'
done

# 6. CoreDNS を元の replica 数に戻す
#    → CNI が存在しない状態で新しい Pod が作られるので Pending のまま待機する
#    ここで戻し忘れると、次章で CNI を入れても CoreDNS の Pod 数が 0 のままになる
kubectl scale deployment coredns -n kube-system --replicas=$COREDNS_REPLICAS
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

クラスタは [00-setup.md](00-setup.md) 完了直後と同じ CNI 未導入の状態に戻りました。
続けて [02-calico.md](02-calico.md) や [03-cilium.md](03-cilium.md) を、
好きな順番で進められます。

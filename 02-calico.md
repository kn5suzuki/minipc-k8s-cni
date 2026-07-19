# Step 2: CNI プラグイン ② — Calico (BGP / IPIP / ネットワークポリシー)

## Calico とは

Calico は本番環境で広く使われる高機能 CNI プラグインです。

- **BGP** でノード間ルートを配布 → L3 ネイティブルーティング (オーバーレイ不要)
- L2 環境では **IPIP** や **VXLAN** でオーバーレイも選択可能
- **ネットワークポリシー** (L3/L4) を完全サポート
- Felix エージェントが各ノードで iptables/eBPF ルールを管理

外側の枠が **ノード**、内側の枠が **Pod の netns** を表す。Flannel の `cni0` のような
共有ブリッジは存在せず、ノードの中では `netns → veth (cali...) → ルーティングテーブル
→ enp1s0` の順に接続される。ノードをまたぐ区間 (`enp1s0` の外、両ノードの間) だけが
BGP ネイティブルーティング、または IPIP でカプセル化される:

```
worker1 (10.244.A.0/26)                       worker2 (10.244.B.0/26)
┌───────────────────────────────┐             ┌───────────────────────────────┐
│    ┌─── Pod A netns ────┐     │             │    ┌─── Pod B netns ────┐     │
│    │  eth0 10.244.A.2   │     │             │    │  eth0 10.244.B.2   │     │
│    └──────────┬─────────┘     │             │    └──────────┬─────────┘     │
│               │ veth (cali...)│             │               │ veth (cali...)│
│               │               │             │               │               │
│      ノードのルーティングテーブル  │             │      ノードのルーティングテーブル  │
│      (Felix/Bird が書き込む)    │             │      (Felix/Bird が書き込む)   │
│               │               │             │               │               │
│            enp1s0             │             │            enp1s0             │
└───────────────┴───────────────┘             └───────────────┴───────────────┘
                │ 192.168.100.12                             │ 192.168.100.13
                │                                            │
                └── BGP ネイティブルーティング or IPIP (tunl0) ──┘
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

## 2.1 Calico のインストール (Operator 方式)

**前提**: [00-setup.md](00-setup.md) でクラスタが構築済みで、全 Node が `NotReady` であること
(CNI 未導入の状態)。すでに Flannel や Cilium を試した後であれば、その章の
アンインストール手順 (または ホストで `make uninstall`) を先に実行してから
始めてください。

Calico には大きく2つのインストール方法があります。

| 方式 | やり方 | 設定変更のしかた |
|---|---|---|
| 従来型の manifest 方式 | `calico.yaml` を1枚 `kubectl apply` (01章の Flannel と同じ発想) | ConfigMap を編集して Pod を再作成 |
| **Operator 方式 (本章で採用)** | 小さな operator を先に入れ、`Installation` という CR で設定を渡す | `Installation` を `kubectl patch` するだけで operator が自動反映 |

Calico 公式ドキュメントでも Operator 方式が推奨されているため、本チュートリアルでは
こちらを採用します。手順は次の3段階です:

1. `tigera-operator.yaml` を apply → operator (コントローラ) 自体をインストールするだけ。
   この時点ではまだ Calico のデータプレーン (calico-node など) は何も動かない。
2. `Installation` という CR を apply → ここで初めて具体的な設定 (CIDR やカプセル化方式) を渡す。
   operator がこれを検知して calico-node などを自動的に作成する。
3. `APIServer` という CR を apply → `calico-apiserver` (Calico 独自リソースを扱う
   aggregated API server) を起動する。今の時点では必須に見えないが、これを省略すると
   2.7 で IPPool の設定を後から変更しようとした際に operator が
   `"Calico API server is unavailable"` で変更を反映できなくなる。

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
      encapsulation: IPIP        # BGP モードの場合は None
      natOutgoing: Enabled
      nodeSelector: all()
EOF

# 3. APIServer CR を apply (calico-apiserver を起動する。省略すると 2.7 で
#    IPPool を後から変更する際に "Calico API server is unavailable" で失敗する)
kubectl apply -f - <<'EOF'
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
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

kubectl get pods -n calico-apiserver -o wide
# calico-apiserver-xxxxx      1/1     Running   worker1
# calico-apiserver-yyyyy      1/1     Running   worker2
```

Node が Ready になったことを確認:

```bash
kubectl get nodes
# NAME      STATUS   ROLES           VERSION
# control   Ready    control-plane   v1.31.x
# worker1   Ready    <none>          v1.31.x
# worker2   Ready    <none>          v1.31.x
```

CoreDNS も Running になっていること (Calico の IPAM から新しい IP が払い出される):

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
```

---

## 2.2 Calico が配置したもの

`calico-system` namespace には役割の異なる複数の Pod が動いています。

| コンポーネント | 種類 | 役割 |
|---|---|---|
| `calico-node` | DaemonSet (全ノードに1つ) | データプレーンの本体。**Felix** (ルート/iptables・eBPFルール programming)、**Bird** (BGPデーモン)、**confd** (datastoreの変更を Bird の設定ファイルに反映) を1コンテナにまとめたもの |
| `calico-typha` | Deployment (既定で2 replica) | Felix と Kubernetes API (datastore) の間に立つキャッシュ用プロキシ |
| `csi-node-driver` | DaemonSet (全ノードに1つ) | Calico の CSI (Container Storage Interface) ドライバ |

### calico-node: Felix / Bird / confd

`calico-node` には2つの initContainer があり、Pod 起動時に1回だけ実行されます:

- `install-cni`: `/etc/cni/net.d/10-calico.conflist` を各ノードに書き込む (次項で中身を見る)
- `flexvol-driver`: 後述の CSI が使われる前の旧方式のボリュームドライバ (互換性のため残存)

### CNI 設定ファイル (10-calico.conflist)

`install-cni` initContainer が各ノードに書き込んだファイルの中身を、worker1 に SSH して
確認する (2.13 のアンインストール手順で最後に削除するファイルの正体):

```bash
ssh ubuntu@worker1 'cat /etc/cni/net.d/10-calico.conflist'
# {
#   "name": "k8s-pod-network",
#   "cniVersion": "0.3.1",
#   "plugins": [
#     { "type": "calico", "datastore_type": "kubernetes", "mtu": 0, ... },
#     { "type": "bandwidth", "capabilities": {"bandwidth": true} },
#     { "type": "portmap", "capabilities": {"portMappings": true} }
#   ]
# }
```

Flannel の `flannel` + `bridge` + `portmap` の chain (1.2) と似た構造だが、Calico は
`bridge` プラグインに委譲しない。`calico` プラグイン自身が Pod ごとの veth 作成・
ルーティングテーブルへの登録までを直接行う (実際の veth は 2.4 で Pod がスケジュール
されて初めて作られる)。

### tunl0 (IPIP トンネルインターフェース)

`flannel.1` (1.2) と同じく、`tunl0` は Pod の有無に関係なく **Calico 導入時点で
各ノードに常に作られる** 静的なインターフェースである (今回は IPIP モードでインストール
したため)。worker1 に SSH して確認する:

```bash
ssh ubuntu@worker1 'ip -d link show tunl0'
# tunl0: <...> mtu 1480 ...
#     ipip remote any local 192.168.100.12 ttl inherit nopmtudisc
# IPIP トンネル (IP-in-IP カプセル化)

ssh ubuntu@worker1 'ip addr show tunl0'
# inet 10.244.x.y/32 scope global tunl0   ← worker1 自身に割り当てられたブロックの Gateway IP
```

- `ipip remote any local 192.168.100.12`: このノードを送信元として、任意のリモート
  ノードへ IPIP カプセル化パケットを送れる設定。
- `mtu 1480`: IPIP ヘッダ (20 byte) 分を差し引いた値。Flannel の VXLAN (50 byte
  差し引き, 1.2) より小さいオーバーヘッドで済む。

実際に `tunl0` がノードをまたぐ通信でどう使われるかは、2.6 でパケットキャプチャと
併せて確認する。

### Pod ごとの veth (cali...) と netns

`calico` CNI プラグインは Pod がスケジュールされるたびに、ホスト側で `cali` から始まる
veth (例: `cali1234abcd`) を作成し、コンテナ側の一端を Pod の netns 内に移動させて
`eth0` にリネームする。Flannel の `cni0` のように全 Pod の veth を1つのブリッジに
ぶら下げるのではなく、Calico は Pod ごとの veth をブリッジを介さず**直接ルーティング
テーブルに接続**する点が大きく異なる。まだこの時点ではノードに Pod が1つも
スケジュールされていないため `cali...` veth は存在しない。2.3 でテスト用 Pod を
デプロイした後、2.4 で実際にこれらが作られたことを確認する。

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

## 2.3 テスト用 Pod をデプロイ

```bash
# nginx (DaemonSet/Service) と debug Pod をまとめてデプロイ
# manifest は manifests/nginx-ds.yaml を参照。01/03章と同じファイルを使い回します
kubectl apply -f manifests/nginx-ds.yaml
```

Pod が Running になるまで待機:

```bash
kubectl get pods -o wide
# NAME            READY   STATUS    NODE      IP
# nginx-ds-xxx    1/1     Running   control   10.244.x.x
# nginx-ds-yyy    1/1     Running   worker1   10.244.x.x
# nginx-ds-zzz    1/1     Running   worker2   10.244.x.x
# debug           1/1     Running   worker1   10.244.x.x
```

---

## 2.4 Calico が Pod 用に構築したもの

2.2 で見た Felix/Bird/confd・`tunl0` はノードに Calico が導入された時点で常駐するが、
2.2 の末尾で触れた各 Pod の veth (`cali...`) やホストのルーティングテーブルへのエントリは、
そのノードに **Pod がスケジュールされて初めて** Felix が書き込む。2.3 で初めて Pod が
デプロイされたことで、worker1 上にこれらが作られたことを確認する。

### Pod ごとの veth (cali...)

```bash
ssh ubuntu@worker1 'ip link show type veth'
# cali1234abcd@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
```

2.2 で説明した通り、Calico は Flannel の `cni0` のように全 Pod の veth を1つのブリッジに
ぶら下げるのではなく、Pod ごとに独立した veth (`cali...`) の一端をホスト側で
**ブリッジを介さずルーティングテーブルに直接** 乗せる。

### proxy ARP と /32 ホストルート

```bash
# ARP proxy が有効 (cali... デバイスで)
ssh ubuntu@worker1 'cat /proc/sys/net/ipv4/conf/cali1234abcd/proxy_arp'
# 1 (有効)
```

- `proxy_arp`: Pod からのデフォルトゲートウェイ宛て ARP に、Felix がこの veth 自身で
  代理応答するための設定。Flannel の `cni0` (Linux Bridge) が L2 スイッチングで
  肩代わりしていた「デフォルトゲートウェイとして振る舞う」役割を、Calico では
  veth ごとの proxy ARP で実現している。
- 実際の Pod ごとの `/32` ホストルートは 2.5 で `ip route get` の出力から確認する。

### iptables で Calico が入れたルール

```bash
ssh ubuntu@worker1 'sudo iptables -L cali-FORWARD -n | head -20'
```

### ここまでで構築されたインターフェース構成

2.2 (Felix/Bird) と本節 (veth・ルーティングテーブル) を合わせると、worker1 上には次のような
インターフェースの連なりが出来上がっている:

```
worker1 (192.168.100.12)
┌──────────────────────────────────────────────────────────────┐
│  debug Pod netns         nginx-ds Pod netns                  │
│  ┌─────────────┐         ┌─────────────┐                     │
│  │ eth0        │         │ eth0        │                     │
│  │10.244.A.y   │         │10.244.A.x   │                     │
│  └──────┬──────┘         └──────┬──────┘                     │
│         │ veth (cali...)        │ veth (cali...)             │
│  ┌──────┴───────────────────────┴─--─────┐                   │
│  │   ノードのルーティングテーブル             │                   │
│  │  (Felix が Pod ごとに /32 route を書く) │                   │
│  └────────────────────┬──────────────────┘                   │
│                       │                                      │
│  ┌────────────────────┴──────────────────┐                   │
│  │   tunl0 (IPIP モード時のみ存在)          │                   │
│  └────────────────────┬-─────────────────┘                   │
│                       │ ノードをまたぐ場合のみ                  │
│                       │ IPIP カプセル化 or BGP ネイティブルーティング │
│  ┌────────────────────┴───────────────────┐                  │
│  │  enp1s0 (物理 NIC, 192.168.100.12)      │                 │
│  └────────────────────────────────────────┘                 │
└─────────────────────────────────────────────────────────────┘
```

**ポイント**: 同一ノード内 (`eth0` → veth → ルーティングテーブル) はブリッジを介さない
L3 ルーティングのみ、ノードをまたぐ場合だけ `tunl0` (IPIP) または BGP ネイティブルート
経由で `enp1s0` に出る。それぞれ 2.5 (同一ノード内) と 2.6 (ノードをまたぐ) で実際の
パケットを見ながら確認する。

---

## 2.5 同一ノード内の Pod 間通信

ノードをまたぐ通信を見る前に、まず **同じノード上の Pod 同士** が Calico 環境で
どう通信するかを確認します。ここでは IPIP/BGP どちらの出番もなく、Pod ごとの
`/32` ホストルートだけで完結することがポイントです。

```bash
# debug Pod と同じノード (worker1) 上の nginx を選ぶ
NGINX_W1=$(kubectl get pod -l app=nginx-ds -o wide | grep worker1 | awk '{print $6}')
kubectl exec debug -- ping -c3 $NGINX_W1

# curl で HTTP レスポンス確認
kubectl exec debug -- wget -qO- $NGINX_W1
```

### Pod 側の ARP 解決 (proxy ARP)

`debug` Pod 自身のルーティングテーブルを見ると、宛先が同一ノードの Pod でも別ノードの
Pod でも、常に同じ1つの経路 (デフォルトゲートウェイ) を通ることがわかる:

```bash
kubectl exec debug -- ip route
# default via 169.254.1.1 dev eth0
```

`169.254.1.1` はどこにも実体を持たないリンクローカルアドレスだが、Pod はこれを
デフォルトゲートウェイとして扱い、フレームを送る前に ARP で MAC アドレスを解決する:

```bash
kubectl exec debug -- ip neigh
# 169.254.1.1 dev eth0 lladdr ee:ee:ee:ee:ee:ee ... STALE
```

`ee:ee:ee:ee:ee:ee` は 2.4 で見た `proxy_arp` によって worker1 側の veth (`cali...`)
自身が代理応答している MAC である。`169.254.1.1` 宛のルートは実際にはどこにも存在
しないが、この veth は Pod と1対1の point-to-point リンクであり相手は Pod しかいない
ため、「この veth 越しに ARP が来たら常に自分の MAC で答える」という単純な仕組みで
成立している。

**ポイント**: Pod は隣に誰がいるかを一切気にせず、常に同じ MAC (ホスト自身) 宛てに
フレームを投げるだけでよい。実際にどの Pod・どのノードへ転送するかは、フレームを
受け取ったホスト側のルーティングテーブル (本節で見た `/32` ホストルートや、2.6 で
見る `tunl0`) が判断する。Flannel の `cni0` (1.5) が通常の L2 ARP/スイッチングで
あったのに対し、Calico は ARP 自体を「常に同じ答えを返すダミー」にして、実質的な
転送判断をすべて L3 ルーティング側に寄せている点が大きな違い。

### ルーティングを確認: /32 ホストルート

```bash
ssh ubuntu@worker1 "ip route get $NGINX_W1"
# NGINX_W1 dev cali1234abcd src ...
# ★ tunl0 ではなく veth (cali...) 直結 = 宛先 Pod ごとの /32 ルート
```

**ポイント**: Flannel の `cni0` は全 Pod の veth を1つのブリッジにぶら下げる L2
スイッチングでしたが、Calico は Felix が Pod ごとに `/32` の個別ルートを書き込み、
**同一ノード内でも Linux のルーティング (L3) で転送**します。

### 物理 NIC にはパケットが出ないことを確認

```bash
ssh ubuntu@worker1 'sudo timeout 5 tcpdump -i enp1s0 -n icmp -c3' &
kubectl exec debug -- ping -c3 $NGINX_W1
wait
# パケット 0 件 = IPIP カプセル化も物理 NIC への送出も発生しない
```

### cali veth 上ではそのまま見える

```bash
ssh ubuntu@worker1 'sudo timeout 5 tcpdump -i cali1234abcd -n icmp -c3' &
kubectl exec debug -- ping -c3 $NGINX_W1
wait
# veth 上では Pod IP 同士のパケットがカプセル化なしでそのまま見える
```

### iperf3 でスループットを計測 (ベースライン)

2.6 (IPIP) / 2.7 (BGP ネイティブ) のノードをまたぐ結果と比較するためのベースラインを、
専用の `iperf3` サーバー/クライアント Pod で測っておく。manifest は
`manifests/iperf3.yaml` (`iperf3-client`/`iperf3-server-w1` は worker1、
`iperf3-server-w2` は worker2 に固定。03 章の Cilium でも同じ manifest を使い回す) を
使う。3つとも一度に作っておき、`iperf3-server-w2` は 2.6/2.7 で使うまでそのまま起動
待機させておく:

```bash
kubectl apply -f manifests/iperf3.yaml
kubectl wait --for=condition=Ready pod/iperf3-client pod/iperf3-server-w1 pod/iperf3-server-w2
```

```bash
IPERF_W1=$(kubectl get pod iperf3-server-w1 -o jsonpath='{.status.podIP}')
kubectl exec iperf3-client -- iperf3 -c $IPERF_W1 -t 5
# [ ID] Interval           Transfer     Bitrate         Retr
# [  5]   0.00-5.00   sec  ... GBytes  ... Gbits/sec    0    sender
# ★ 同一ノード内は上で確認した通り veth (cali...) への /32 ホストルート直結のみで、
#   IPIP/BGP ネイティブどちらのモードでも経路は変わらないベースライン値
```

同一ノード用のサーバーはもう使わないので削除する (`iperf3-client` は 2.6/2.7 で
使い回すため残しておく):

```bash
kubectl delete pod iperf3-server-w1
```

**まとめ**: 同一ノード内は Pod ごとの `/32` ホストルートによる直接ルーティングのみ。
次の 2.6 で確認する「ノードをまたぐ通信」だけが IPIP トンネル (`tunl0`) や BGP
ネイティブルーティングを必要とします。

---

## 2.6 ノードをまたいだ Pod 間通信

2.5 とは対照的に、ここでは意図的に **別ノード (worker2)** 上の nginx を選び、IPIP
トンネル経由の通信を確認します。以下、2.5 と同じ手順 (ping/wget → ルーティング確認
→ パケットキャプチャ) を辿りながら、結果がどう変わるかを見比べます。

```bash
# debug Pod から worker2 の nginx に ping
NGINX_W2=$(kubectl get pod -l app=nginx-ds -o wide | grep worker2 | awk '{print $6}')
kubectl exec debug -- ping -c3 $NGINX_W2

# curl で HTTP レスポンス確認
kubectl exec debug -- wget -qO- $NGINX_W2
```

### ルーティングテーブルと tunl0

```bash
ssh ubuntu@worker1 "ip route get $NGINX_W2"
# NGINX_W2 via 192.168.100.13 dev tunl0 src ...
# ★ 2.5 の veth 直結とは違い、今度は tunl0 経由 = IPIP トンネルへ

ssh ubuntu@worker1 'ip route | grep tunl0'
# 10.244.A.0/26 via 192.168.100.11 dev tunl0 proto bird  # control のブロック
# 10.244.B.0/26 via 192.168.100.13 dev tunl0 proto bird  # worker2 のブロック
# ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
# proto bird = Bird BGP デーモンがインストールしたルート
# A, B は環境ごとに異なる (冒頭の注を参照)。自ノードのブロックは
# tunl0 経由ではなくローカルルーティングされるためここには出てこない。
```

**ポイント**: 2.5 では宛先が自ノードの Pod サブネットだったため veth 止まりでしたが、
ここでは宛先 (worker2 の `10.244.B.0/26`) が他ノードの Pod サブネットなので、2.2 で
見た `tunl0` 経由でルーティングされます。IPIP トンネルが初めて実際の通信で使われます。

### 物理 NIC でキャプチャ: 今度は IPIP パケットが見える

```bash
# 物理NIC で見えないことを確認した 2.5 とは対照的に、ここではキャプチャに残す
ssh ubuntu@worker1 'sudo tcpdump -i enp1s0 -n proto 4 -w /tmp/calico-ipip.pcap' &

kubectl exec debug -- wget -qO- $NGINX_W2

ssh ubuntu@worker1 'sudo pkill tcpdump'
ssh ubuntu@worker1 'sudo tcpdump -r /tmp/calico-ipip.pcap -n -v | head -10'
# 192.168.100.12 > 192.168.100.13: IP 10.244.A.x > 10.244.B.y: ...
# 外側: ノード IP, プロトコル 4 (IPIP)
# 内側: Pod IP
```

**まとめ**: 2.5 (同一ノード内) は veth 直結の L3 ルーティングだけで完結し、物理 NIC
には一切パケットが出ませんでした。2.6 (ノードをまたぐ) では `tunl0` が宛先ノード
へ向けて IPIP カプセル化し、物理 NIC 上にノード IP 同士のプロトコル 4 パケットとして
現れます。

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

**ポイント**: `proto bird` が示す通り、IPIP モードであってもルート自体の配布は BGP
(Bird) が担っています。IPIP はあくまでカプセル化の方式であり、ルート配布そのものは
2.7 で見る BGP ネイティブモードと同じ Bird が行っています。

### iperf3 でスループットを計測 (IPIP 経由)

2.5 で `manifests/iperf3.yaml` と一緒に起動しておいた `iperf3-server-w2` (worker2) と
`iperf3-client` (worker1) をそのまま使う。この `iperf3-server-w2` は 2.7 の BGP
ネイティブルーティングとの比較にも再利用するため、ここでは削除せずに残しておく。

```bash
IPERF_W2=$(kubectl get pod iperf3-server-w2 -o jsonpath='{.status.podIP}')
kubectl exec iperf3-client -- iperf3 -c $IPERF_W2 -t 5
# [ ID] Interval           Transfer     Bitrate         Retr
# [  5]   0.00-5.00   sec   ... MBytes  ... Mbits/sec    x    sender
# IPIP のカプセル化/デカプセル化コスト (MTU 1480 への分割、CPU 処理) が乗った状態の値

# 参考: RTT の平均もついでに見ておく (2.7 の値と比較する)
# iperf3-client の networkstatic/iperf3 イメージには ping が入っていないため、
# 同じ worker1 上にいる debug (busybox) から ping する
kubectl exec debug -- ping -c 20 -q $IPERF_W2 | tail -3
```

この iperf3/ping の値は、次の 2.7 で BGP ネイティブルーティングに切り替えた後の
値と比較する。

---

## 2.7 BGP モード (ネイティブルーティング) に切り替え

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
        "natOutgoing": "Enabled",
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

### iperf3 で再計測 (BGP ネイティブルーティング経由)

2.6 で使った `iperf3-server-w2` / `iperf3-client` はそのまま残っているので、Pod を
作り直さずにモード切り替えの影響だけを計測できる:

```bash
kubectl exec iperf3-client -- iperf3 -c $IPERF_W2 -t 5
# [ ID] Interval           Transfer     Bitrate         Retr
# [  5]   0.00-5.00   sec   ... MBytes  ... Mbits/sec    x    sender
# IPIP のカプセル化/デカプセル化が無くなった状態の値。2.6 の結果と見比べる

kubectl exec debug -- ping -c 20 -q $IPERF_W2 | tail -3
# rtt min/avg/max/mdev = ... ms
# 2.6 (IPIP) の平均 RTT と比較する
```

**ポイント**: このラボの物理 NIC は 1GbE のため、スループット自体は NIC がボトルネックに
なり IPIP/BGP ネイティブの差が誤差程度に収まることもある。差が出やすいのはむしろ

- **RTT** (IPIP はパケットごとにカプセル化/デカプセル化の処理が挟まる分だけ増える)
- `iperf3` 出力の **Retr** (再送) 列 (MTU 1480 への分割で発生しやすい)
- ノードの CPU 使用率 (`ssh ubuntu@worker1 mpstat 1 3` などでカプセル化処理のコストを見る)

の3点。10GbE 以上の環境ではスループット自体の差もより顕著に出やすい (Cilium の
VXLAN/ネイティブ比較 (03 章 3.7) も同じ傾向)。

計測用 Pod を片付ける:

```bash
kubectl delete pod iperf3-client iperf3-server-w2 --ignore-not-found
```

### 参考: IPIP モードに戻す手順

以降の章 (2.8〜2.13) はどちらのモードでも進められるため、切り戻しは必須ではない
(2.13 のアンインストールは `tunl0` を無条件で削除するため、IPIP/BGP どちらの状態から
実行しても同じ手順で完了する)。2.1 でインストールした IPIP の状態に戻したい場合は、
`encapsulation` を `None` から `IPIP` に patch し直すだけでよい:

```bash
kubectl patch installation default --type merge -p '
{
  "spec": {
    "calicoNetwork": {
      "ipPools": [{
        "name": "default-ipv4-ippool",
        "cidr": "10.244.0.0/16",
        "encapsulation": "IPIP",
        "natOutgoing": "Enabled",
        "nodeSelector": "all()"
      }]
    }
  }
}'
```

戻ったことを確認:

```bash
# 再び tunl0 経由になる
ssh ubuntu@worker1 'ip route | grep tunl0'
# 10.244.A.0/26 via 192.168.100.11 dev tunl0 proto bird
# 10.244.B.0/26 via 192.168.100.13 dev tunl0 proto bird

kubectl exec debug -- ping -c3 $NGINX_W2
```

---

## 2.8 Service の通信経路 (kube-proxy × iptables)

Calico 自体は Service を扱わず、ClusterIP → Pod の変換は Flannel と同じく kube-proxy が
iptables で行います (本章の設定では kube-proxy を置き換えていません)。Calico が受け持つ
のは、その変換後の宛先 Pod IP への実際の転送 (2.5/2.6/2.7 で見た経路) です。

```bash
# Service の ClusterIP を確認
kubectl get svc nginx-svc
# NAME        TYPE        CLUSTER-IP    PORT(S)
# nginx-svc   ClusterIP   10.96.x.y     80/TCP

CLUSTER_IP=$(kubectl get svc nginx-svc -o jsonpath='{.spec.clusterIP}')

# ClusterIP 宛てに curl (debug Pod から)
kubectl exec debug -- wget -qO- $CLUSTER_IP
```

### KUBE-SERVICES → KUBE-SVC-xxx → KUBE-SEP-xxx

```bash
ssh ubuntu@worker1 "sudo iptables -t nat -L KUBE-SERVICES -n | grep $CLUSTER_IP"
# KUBE-SVC-xxx  tcp  -- 0.0.0.0/0  10.96.x.y  tcp dpt:80

ssh ubuntu@worker1 "sudo iptables -t nat -L KUBE-SVC-xxx -n"
# KUBE-SEP-aaa  all  --  0.0.0.0/0  0.0.0.0/0  statistic mode random probability 0.33333
# KUBE-SEP-bbb  all  --  0.0.0.0/0  0.0.0.0/0  statistic mode random probability 0.50000
# KUBE-SEP-ccc  all  --  0.0.0.0/0  0.0.0.0/0

ssh ubuntu@worker1 "sudo iptables -t nat -L KUBE-SEP-aaa -n"
# DNAT  tcp  --  0.0.0.0/0  0.0.0.0/0  tcp to:10.244.A.x:80
```

**まとめ**: 01章 (1.7) と全く同じ `KUBE-SERVICES → KUBE-SVC-xxx → KUBE-SEP-xxx` の
チェーンで ClusterIP:80 が特定の Pod IP:80 へ DNAT されます。DNAT が済んだ時点で
パケットは通常の Pod 宛てパケットと同じになるため、そこから先の転送経路は選ばれた
Pod が同一ノードか別ノードかによって 2.5 (veth 直結) か 2.6/2.7 (`tunl0` 経由の IPIP、
または BGP ネイティブ) のどちらかに合流します。Calico から見ても Service は関知しない、
kube-proxy が Pod IP を差し替えるだけの前段処理である点は Flannel と同じです。

---

## 2.9 ネットワークポリシーを試す

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

## 2.10 Pod からインターネットへの疎通

Calico では IPPool の `natOutgoing` 設定 (2.1 でインストール時に `Enabled` を
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

## 2.11 calicoctl のインストール (任意)

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

## 2.12 Calico のまとめ

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

## 2.13 Calico のアンインストール (CNI 未導入の状態に戻す)

**参考**: 以下の手順のうち Calico 本体・各ノードのインターフェース・CNI 設定ファイルの
削除は、ホスト側で `make uninstall` を実行すれば1コマンドで完了します (`Makefile` の
`uninstall` ターゲットの実体がまさにこの操作です)。学習目的で一つずつ確認したい場合は、
以下を手動で実行してください。

**注意**: [1.10](01-flannel.md#110-flannel-のアンインストール-cni-未導入の状態に戻す)
と同じ理由で、CoreDNS Pod は `kubectl delete pod` ではなく Deployment を一時的に
0 replica に `scale` することで削除します。Pod を消すには kubelet が CNI DEL を呼んで
ネットワークを片付ける必要があり、それには CNI 設定がまだ存在している必要があります。
そのため CoreDNS の削除は CNI 削除より**前**に、再作成 (scale を元に戻す) は CNI 削除
より**後**に行います。

```bash
# 1. テスト用リソースを削除 (Calico の IP を持ったまま残さない)
kubectl delete -f manifests/nginx-ds.yaml --ignore-not-found

# 2. CoreDNS を一時的に 0 replica にする (CNI がまだ生きている今のうちに
#    Pod をきれいに削除させる。ReplicaSet による再作成も防げる)
COREDNS_REPLICAS=$(kubectl get deployment coredns -n kube-system -o jsonpath='{.spec.replicas}')
kubectl scale deployment coredns -n kube-system --replicas=0
kubectl wait --for=delete pod -n kube-system -l k8s-app=kube-dns --timeout=60s

# 3. Calico 本体を削除 (2.1 で apply した Installation/APIServer CR と operator 自体)
kubectl delete installation default apiserver default 2>/dev/null || true
kubectl delete -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml

# CRD を削除
kubectl get crds | grep calico | awk '{print $1}' | xargs kubectl delete crd 2>/dev/null || true
kubectl get crds | grep tigera | awk '{print $1}' | xargs kubectl delete crd 2>/dev/null || true

# Namespace 削除
kubectl delete ns calico-system calico-apiserver tigera-operator 2>/dev/null || true

# 4. 各ノードの Calico が作ったインターフェースを削除
for node in control worker1 worker2; do
  ssh ubuntu@$node 'sudo ip link delete tunl0 2>/dev/null; \
    for i in $(ip link show type veth | grep cali | awk -F: "{print \$2}"); do \
      sudo ip link delete $i 2>/dev/null; done; true'
done

# 5. CNI 設定ファイルを削除
for node in control worker1 worker2; do
  ssh ubuntu@$node 'sudo rm -f /etc/cni/net.d/10-calico.conflist /etc/cni/net.d/calico-kubeconfig'
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
続けて [01-flannel.md](01-flannel.md) や [03-cilium.md](03-cilium.md) を、
好きな順番で進められます。3 つとも試したら [04-comparison.md](04-comparison.md)
で比較しましょう。

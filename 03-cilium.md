# Step 3: CNI プラグイン ③ — Cilium (eBPF データプレーン + Hubble 可視化)

## Cilium とは

Cilium は Linux カーネルの **eBPF (extended Berkeley Packet Filter)** を活用した次世代 CNI です。

- **iptables を使わない** → カーネルネイティブの eBPF プログラムで転送
- **kube-proxy の完全置き換え** (Cilium KubeProxy Replacement)
- **L7 ネットワークポリシー** (HTTP メソッド、パス、gRPC など)
- **Hubble**: eBPF ベースの可観測性プラットフォーム (フロー可視化)

外側の枠が **ノード**、内側の枠が **Pod の netns** を表す。Flannel の `cni0` や Calico の
ルーティングテーブルのような転送判断を、Cilium では veth (`lxc...`) にアタッチされた
**TC eBPF hook** が担う。ノードの中では `netns → veth (lxc...) → TC eBPF hook → enp1s0`
の順に接続され、ノードをまたぐ区間 (`enp1s0` の外、両ノードの間) だけが VXLAN で
カプセル化される:

```
worker1 (10.244.1.0/24)                    worker2 (10.244.2.0/24)
┌────────────────────────────────────┐     ┌────────────────────────────────────┐
│    ┌─── Pod A netns ────┐          │     │    ┌─── Pod B netns ────┐          │
│    │  eth0 10.244.1.2   │          │     │    │  eth0 10.244.2.2   │          │
│    └──────────┬─────────┘          │     │    └──────────┬─────────┘          │
│               │ veth (lxc...)      │     │               │ veth (lxc...)      │
│               │                    │     │               │                    │
│  TC eBPF hook (cil_from_container,  │     | TC eBPF hook (cil_from_container,  |
│   ingress のみ) が転送判断            │     |  ingress のみ) が転送判断            |
│               │                    │     │               │                    │
│         cilium_vxlan (VXLAN)       │     │         cilium_vxlan (VXLAN)       │
│               │                    │     │               │                    │
│            enp1s0                  │     │            enp1s0                  │
└───────────────┴────────────────────┘     └───────────────┴────────────────────┘
                │ 192.168.100.12                           │ 192.168.100.13
                │                                          │
                └──── VXLAN encapsulation (UDP/8472) ──────┘
```

**注**: このラボでは Helm values で `ipam.mode=kubernetes` を指定しており、Cilium は
Calico 自身の IPAM (2.x 章参照) ではなく **kubeadm が各ノードに払い出した PodCIDR
(`/24`)** をそのまま使う。そのため Pod サブネットの割り当ては Flannel と同じ
`10.244.1.0/24` (worker1) / `10.244.2.0/24` (worker2) というノード番号順の連番になる。

---

## 3.1 Cilium のインストール (kube-proxy 置き換えモード)

**前提**: [00-setup.md](00-setup.md) でクラスタが構築済みで、全 Node が `NotReady` であること
(CNI 未導入の状態)。すでに Flannel や Calico を試した後であれば、その章の
アンインストール手順 (または ホストで `make uninstall`) を先に実行してから
始めてください。

> **注意**: `kubeadm init` 時に kube-proxy を無効化していない場合、
> Cilium は kube-proxy と共存させるか、`kubeProxyReplacement: true` で置き換えるかを選べます。
> このラボでは kube-proxy 置き換えモードを使います。

```bash
# ホストで実行: Helm のインストール
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version

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
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan
```

> **注**: `tunnel=vxlan` は Cilium v1.14 で非推奨化され v1.15 で削除された。
> 現行版では `routingMode=tunnel` (トンネルモードを使うか) と `tunnelProtocol=vxlan`
> (どのプロトコルでカプセル化するか) の2つの値に分割されている。

インストール確認 (3〜5 分待つ):

```bash
# Cilium Pod の状態確認
watch kubectl get pods -n kube-system -l k8s-app=cilium -o wide

# Cilium CLI で確認
cilium status --wait
# ✅ Cilium は全ノードで Ready のはず
```

Node が Ready になったことを確認:

```bash
kubectl get nodes
# NAME      STATUS   ROLES           VERSION
# control   Ready    control-plane   v1.31.x
# worker1   Ready    <none>          v1.31.x
# worker2   Ready    <none>          v1.31.x
```

CoreDNS も Running になっていること (Cilium がスケジュール可能になった時点で自動的に
Running へ移行する。追加の操作は不要):

```bash
kubectl get pods -n kube-system -l k8s-app=kube-dns -o wide
```

---

## 3.2 Cilium が配置したもの

### cilium-agent (DaemonSet)

`cilium` DaemonSet は各ノードに1つずつ配置される Pod で、そのノードの eBPF プログラムの
ロード・維持と CNI プラグインとしての振る舞いの両方を担う。この Pod がまだ `Running` に
なっていない (= ノードに CNI が導入されていない) 間は、そのノードは `NotReady` のままとなる
(3.1 で確認した通り)。

```bash
kubectl get pods -n kube-system -l k8s-app=cilium -o wide
```

Hubble 関連の Pod (`hubble-relay`, `hubble-ui`) も同じ namespace に配置されている:

```bash
kubectl get pods -n kube-system -l 'k8s-app in (hubble-relay,hubble-ui)' -o wide
```

### CNI 設定ファイル

`cilium-agent` が各ノードに書き込んだファイルの中身を、worker1 に SSH して確認する:

```bash
ssh ubuntu@worker1 'cat /etc/cni/net.d/05-cilium.conflist'
# {
#   "cniVersion": "0.3.1",
#   "name": "cilium",
#   "plugins": [
#     { "type": "cilium-cni", ... }
#   ]
# }
```

Flannel (`flannel` + `bridge` + `portmap` の chain, 1.2) や Calico (`calico` + `bandwidth`
+ `portmap` の chain, 2.2) と違い、`cilium-cni` は他のプラグインに委譲せず単独で Pod ごとの
veth 作成・eBPF プログラムのアタッチまでを直接行う (実際の veth は 3.4 で Pod がスケジュール
されて初めて作られる)。

### cilium_net / cilium_host / cilium_vxlan (常駐インターフェース)

Flannel の `flannel.1` (1.2) や Calico の `tunl0` (2.2) と同じく、これらは Pod の有無に
関係なく **Cilium 導入時点で各ノードに常に作られる** 静的なインターフェースである。
worker1 に SSH して確認する:

```bash
ssh ubuntu@worker1 'ip -d link show cilium_vxlan'
# cilium_vxlan: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1450 ...
#     vxlan id 0 srcport 0 0 dstport 8472 ...
# ノードをまたぐ Pod 間通信をカプセル化する VXLAN デバイス
# (3.1 で routingMode=tunnel, tunnelProtocol=vxlan を指定したため)

ssh ubuntu@worker1 'ip -d addr show cilium_host'
# cilium_host: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 ...
#     inet 10.244.1.x/32 scope link cilium_host
# ノード自身がこのノードの Pod サブネットへの経路を持つための veth pair の片割れ
# (もう片方は cilium_net。ホストのネットワークスタックと Pod ネットワークを繋ぐ)
```

実際にこれらが Pod 間通信でどう使われるかは、3.5 (同一ノード内) と 3.6 (ノードをまたぐ)
で確認する。

---

## 3.3 テスト用 Pod をデプロイ

```bash
# nginx (DaemonSet/Service) と debug Pod をまとめてデプロイ
# manifest は manifests/nginx-ds.yaml を参照。01/02章と同じファイルを使い回します
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

kubectl wait --for=condition=Ready pod/debug
```

---

## 3.4 Cilium が Pod 用に構築したもの

3.2 で見た `cilium-agent` 本体や `cilium_vxlan` などはノードに CNI が導入された時点で
存在するが、Pod ごとの veth (`lxc...`) と、そこにアタッチされる TC eBPF プログラムは、
そのノードに **Pod がスケジュールされて初めて** `cilium-cni` が作成する。3.3 で初めて
Pod がデプロイされたことで、worker1 上にこれらが作られたことを確認する。

### Pod ごとの veth (lxc...)

```bash
ssh ubuntu@worker1 'ip link show type veth'
# lxc12345678@if2: <BROADCAST,MULTICAST,UP,LOWER_UP> ...
```

Flannel の `cni0` (1.4) のように全 Pod の veth を1つのブリッジにぶら下げるのでも、Calico
の `cali...` (2.4) のようにルーティングテーブルに直接乗せるのでもなく、Cilium は veth の
ホスト側 (`lxc...`) に **TC (Traffic Control) eBPF プログラム**をアタッチし、そこで
転送判断そのものを完結させる。

### veth にアタッチされた TC eBPF プログラム

> **注**: 最近の Cilium (kernel が対応していれば) は TC プログラムを従来の
> `cls_bpf`/`tc filter` ではなく、カーネルの **tcx** リンク機構でアタッチする。
> そのため `tc filter show dev <iface> ingress` では何も表示されない。
> 代わりに `bpftool net show` を使う。表示は従来と同じ `tc:` セクションの中に出るが、
> 各エントリの先頭に `tcx/ingress` という接頭辞が付き、legacy な `cls_bpf` アタッチとは
> 区別される (この接頭辞が付いていること自体が、tcx が使われている証拠)。

```bash
ssh ubuntu@worker1 'sudo bpftool net show dev lxc12345678'
# xdp:
#
# tc:
# lxc12345678(10) tcx/ingress cil_from_container prog_id 283 link_id 12
```

- `cil_from_container`: veth のホスト側 (`lxc...`) の **ingress** (= Pod から出て
  くる方向) にだけアタッチされる eBPF プログラム。宛先が同一ノードの Endpoint かどうかを
  **eBPF Map** (後述) で判定し、`bpf_redirect_peer()` で宛先 veth の netns へ直接
  配送するか、別ノードなら `cilium_vxlan` へ回す。
- Flannel/Calico のように「送信側の処理」と「受信側の処理」が別インターフェースの
  別フックに分かれているわけではなく、**送信側 veth の ingress フック1箇所で
  ポリシー判定から配送までが完結する** (eBPF host-routing)。そのため宛先側の
  veth には対になる TC プログラムは付かない — `sudo bpftool net show dev <宛先の lxc...>`
  を実行しても `tc:` セクションは空になる。

ロードされている eBPF プログラム全体は次のコマンドでも確認できる:

```bash
ssh ubuntu@worker1 'sudo bpftool prog list | grep -E "sched_cls|xdp" | head -20'
# ID: xxx  type: sched_cls  name: cil_from_container  ...
# ID: zzz  type: xdp        name: cil_xdp_entry        ...
```

**ポイント**: `cil_to_container` という名前のプログラムも `bpf_lxc.o` の一部として
コンパイルはされているが、tail call 経由でのみ使われ、独立した TC フックとしては
アタッチされない (host-routing が有効な場合)。実際に何がアタッチされているかは
`bpftool prog list` の一覧ではなく、必ず `bpftool net show` で確認すること。

**ポイント**: `sched_cls` は Linux TC の hook 種別。iptables のようなグローバルな
ルールテーブルではなく、Pod ごとの veth に個別の eBPF プログラムが刺さっている点が
Flannel/Calico とは根本的に異なる。

### ここまでで構築されたインターフェース構成

3.2 (`cilium_vxlan`/`cilium_host`) と本節 (veth・TC eBPF) を合わせると、worker1 上には
次のようなインターフェースの連なりが出来上がっている:

```
worker1 (192.168.100.12)
┌──────────────────────────────────────────────────────────┐
│  debug Pod netns         nginx-ds Pod netns              │
│  ┌─────────────┐         ┌─────────────┐                 │
│  │ eth0        │         │ eth0        │                 │
│  │10.244.1.y   │         │10.244.1.x   │                 │
│  └──────┬──────┘         └──────┬──────┘                 │
│         │ veth (lxc...)         │ veth (lxc...)          │
│  ┌──────┴───────────────────────┴─--─────┐               │
│  │  TC eBPF hook (cil_from_container,     │               │
│  │  送信元 veth の ingress のみ) が        │               │
│  │  eBPF Map で転送判断・直接配送           │               │
│  └────────────────────┬──────────────────┘               │
│                       │                                  │
│  ┌────────────────────┴──────────────────┐               │
│  │ cilium_vxlan (VXLAN, mtu 1450)        │               │
│  └────────────────────┬-─────────────────┘               │
│                       │ VXLAN カプセル化                   │
│                       │ (UDP/8472, ノードをまたぐ場合のみ)   │
│  ┌────────────────────┴───────────────────┐              │
│  │  enp1s0 (物理 NIC, 192.168.100.12)      │              │
│  └────────────────────────────────────────┘              │
└──────────────────────────────────────────────────────────┘
```

**ポイント**: 同一ノード内 (`eth0` → `lxc...` → TC eBPF hook) は宛先 veth への直接
redirect、ノードをまたぐ場合のみ `cilium_vxlan` → `enp1s0` という経路で VXLAN
カプセル化される。それぞれ 3.5 (同一ノード内) と 3.6 (ノードをまたぐ) で実際のパケットを
見ながら確認する。

---

## 3.5 同一ノード内の Pod 間通信

ノードをまたぐ通信を見る前に、まず **同じノード上の Pod 同士** が Cilium 環境で
どう通信するかを確認します。ここでは VXLAN の出番がなく、TC eBPF hook による
veth 間の直接 redirect だけで完結することがポイントです。

```bash
# debug Pod と同じノード (worker1) 上の nginx を選ぶ
NGINX_W1=$(kubectl get pod -l app=nginx-ds -o wide | grep worker1 | awk '{print $6}')
kubectl exec debug -- ping -c3 $NGINX_W1

# curl で HTTP レスポンス確認
kubectl exec debug -- wget -qO- $NGINX_W1
```

### cilium_vxlan にはパケットが現れないことを確認

```bash
ssh ubuntu@worker1 'sudo timeout 5 tcpdump -i cilium_vxlan -n -c3' &
kubectl exec debug -- ping -c3 $NGINX_W1
wait
# パケット 0 件 = 同一ノード内は VXLAN トンネルを経由しない
```

### 物理 NIC にもパケットが出ないことを確認

```bash
ssh ubuntu@worker1 'sudo timeout 5 tcpdump -i enp1s0 -n icmp -c3' &
kubectl exec debug -- ping -c3 $NGINX_W1
wait
# パケット 0 件 = enp1s0 (物理 NIC) をまったく経由していない証拠
```

### TC eBPF が直接 redirect していることを確認

```bash
ssh ubuntu@worker1 'ip link show | grep lxc'
# lxcXXXXXX (debug 側) と lxcYYYYYY (同一ノードの nginx 側) がそれぞれ見える

ssh ubuntu@worker1 'sudo bpftool net show dev lxcXXXXXX'
# tc:
# lxcXXXXXX(10) tcx/ingress cil_from_container prog_id ... link_id ...
# ★ 宛先が同一ノードの Endpoint と判定されると、ホストのネットワークスタックを
#   ほぼ経由せず宛先 veth (lxcYYYYYY) へ直接 redirect される
```

### iperf3 でスループットを計測 (ベースライン)

3.6 (VXLAN) / 3.7 (ネイティブルーティング) のノードをまたぐ結果と比較するための
ベースラインを、専用の `iperf3` サーバー/クライアント Pod で測っておく。manifest は
`manifests/iperf3.yaml` (`iperf3-client`/`iperf3-server-w1` は worker1、
`iperf3-server-w2` は worker2 に固定) を使う。02/03 章など他の CNI 章でも同じ
manifest を使い回す。3つとも一度に作っておき、`iperf3-server-w2` は 3.6/3.7 で
使うまでそのまま起動待機させておく:

```bash
kubectl apply -f manifests/iperf3.yaml
kubectl wait --for=condition=Ready pod/iperf3-client pod/iperf3-server-w1 pod/iperf3-server-w2
```

```bash
IPERF_W1=$(kubectl get pod iperf3-server-w1 -o jsonpath='{.status.podIP}')
kubectl exec iperf3-client -- iperf3 -c $IPERF_W1 -t 5
# [ ID] Interval           Transfer     Bitrate         Retr
# [  5]   0.00-5.00   sec  1.09 GBytes  1.87 Gbits/sec    0    sender
# ★ 同一ノード内は上で確認した通り TC eBPF hook の直接 redirect のみで、
#   VXLAN/ネイティブどちらのモードでも経路は変わらないベースライン値
```

**まとめ**: 同一ノード内は eBPF による veth 間の直接 redirect のみ。
次の 3.6 で確認する「ノードをまたぐ通信」だけが `cilium_vxlan` 経由の VXLAN
カプセル化を必要とします。

---

## 3.6 ノードをまたいだ Pod 間通信

**別ノード (worker2)** 上の nginx を選び、VXLAN オーバーレイ経由の通信を確認します。以下、
3.5 と同じ手順 (ping/wget → 判定に使われる情報の確認 → パケットキャプチャ) を辿りながら、
結果がどう変わるかを見比べます。

```bash
NGINX_W2=$(kubectl get pod -l app=nginx-ds -o wide | grep worker2 | awk '{print $6}')
kubectl exec debug -- ping -c3 $NGINX_W2
kubectl exec debug -- wget -qO- $NGINX_W2
```

### eBPF Map (ipcache) で宛先ノードを判定

Flannel は `bridge fdb`、Calico は BGP が学習したルーティングテーブルで宛先ノードを
判定していましたが (1.6/2.6)、Cilium はこれを eBPF Map 上で行います。

```bash
ssh ubuntu@worker1 'sudo bpftool map list | grep cilium | head -10'
# ID: x  name: cilium_ct4_global  type: hash  ...  (接続追跡テーブル)
# ID: y  name: cilium_ipcache     type: hash  ...  (Pod IP → ノード IP マッピング)

ssh ubuntu@worker1 'sudo bpftool map dump name cilium_ipcache 2>/dev/null | head -20'
# key: 10.244.0.x/32  value: 192.168.100.11 (control)
# key: 10.244.2.y/32  value: 192.168.100.13 (worker2)
```

**ポイント**: `cil_from_container` はこの `cilium_ipcache` を引いて宛先 Pod IP が
どのノードに属するかを判定する。自ノード宛てなら 3.5 の veth 直接 redirect、他ノード
宛てなら `cilium_vxlan` への転送を選ぶ。iptables の線形スキャンと異なり、Map の検索は
O(1) で完結する。

### 物理 NIC で VXLAN カプセル化を確認

Helm values で `routingMode=tunnel` / `tunnelProtocol=vxlan` を指定しているため、Flannel と同じ UDP/8472 が使われます:

```bash
ssh ubuntu@worker1 'sudo tcpdump -i enp1s0 -n udp port 8472 -w /tmp/cilium-vxlan.pcap' &
kubectl exec debug -- wget -qO- $NGINX_W2
ssh ubuntu@worker1 'sudo pkill tcpdump'

ssh ubuntu@worker1 'sudo tcpdump -r /tmp/cilium-vxlan.pcap -n -v | head -10'
# 192.168.100.12.xxxx > 192.168.100.13.8472: VXLAN, flags [I] (0x08), vni ...
# IP 10.244.1.y > 10.244.2.x: ...
# 外側: ノード IP + VXLAN、内側: Pod IP (Flannel の 1.6 と同じ構造)
```

### iperf3 でスループットを計測 (VXLAN 経由)

3.5 で `manifests/iperf3.yaml` と一緒に起動しておいた `iperf3-server-w2` (worker2) と
`iperf3-client` (worker1) をそのまま使う。この `iperf3-server-w2` は 3.7 の
ネイティブルーティングとの比較にも再利用するため、ここでは削除せずに残しておく。

```bash
IPERF_W2=$(kubectl get pod iperf3-server-w2 -o jsonpath='{.status.podIP}')
kubectl exec iperf3-client -- iperf3 -c $IPERF_W2 -t 5
# [ ID] Interval           Transfer     Bitrate         Retr
# [  5]   0.00-5.00   sec   ... MBytes  ... Mbits/sec    x    sender
# VXLAN のカプセル化/デカプセル化コスト (MTU 1450 への分割、CPU 処理) が乗った状態の値

# 参考: RTT の平均もついでに見ておく (3.7 の値と比較する)
# iperf3-client の networkstatic/iperf3 イメージには ping が入っていないため、
# 同じ worker1 上にいる debug (busybox) から ping する
kubectl exec debug -- ping -c 20 -q $IPERF_W2 | tail -3
```

**まとめ**: 3.5 (同一ノード内) は TC eBPF hook による veth 間の直接 redirect だけで
完結し、物理 NIC には一切パケットが出ませんでした。3.6 (ノードをまたぐ) では
`cilium_ipcache` を引いた結果 `cilium_vxlan` へ回され、物理 NIC 上にノード IP 同士の
VXLAN パケットとして現れます。この判定はすべて eBPF Map 上で行われ、iptables は
一切関与しません (3.8 で確認します)。この iperf3/ping の値は、次の 3.7 で
ネイティブルーティングに切り替えた後の値と比較する。

---

## 3.7 ネイティブルーティングモードに切り替え

同一 L2 セグメントなので、VXLAN オーバーレイなしのネイティブルーティングが可能です。
Calico の BGP (2.7、Bird デーモンによるルート配布プロトコル) とは異なり、Cilium は
デフォルトでは BGP を使わず、`autoDirectNodeRoutes` を有効にすると Cilium agent 自身が
Kubernetes API から得た各ノードの PodCIDR 情報をもとに、同一 L2 上の他ノードへの直接
ルートを netlink で書き込みます。BGP セッションは一切張られません。3.1 で VXLAN
トンネルモードのままインストールしたため、ここでは Helm の values を更新
(`helm upgrade`) して切り替えます。

```bash
helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --reuse-values \
  --set routingMode=native \
  --set ipv4NativeRoutingCIDR=10.244.0.0/16 \
  --set autoDirectNodeRoutes=true
```

> **注意**: `helm upgrade` は `cilium-config` ConfigMap は書き換えるが、DaemonSet の
> Pod テンプレート自体は変更しないため、Kubernetes は「ロールアウトすべき差分」を
> 検知しない。そのままだと既存の Pod は起動時に読み込んだ古い設定 (tunnel モード) を
> 動かし続けてしまい、`kubectl rollout status` は (何も待つものがないので) 一見
> 成功したように見えるが実際には反映されていない。設定を反映させるには明示的に
> ロールアウトを起動する必要がある。

```bash
kubectl -n kube-system rollout restart daemonset cilium
kubectl -n kube-system rollout status daemonset cilium
cilium status --wait
```

切り替わったことを確認:

```bash
# エージェント自身が Native だと認識しているか (ここが Tunnel [vxlan] のままなら
# 上のロールアウトがまだ終わっていない/効いていない。rollout status の完了を待ってから再確認する)
CILIUM_POD=$(kubectl get pod -n kube-system -l k8s-app=cilium -o name | head -1)
kubectl exec -n kube-system $CILIUM_POD -- cilium status | grep Routing
# Routing:   Network: Native   Host: Legacy

# VXLAN トンネルが使われなくなり、enp1s0 への直接ルートに置き換わる
ssh ubuntu@worker1 'ip route | grep 10.244'
# 10.244.0.0/24 via 192.168.100.11 dev enp1s0   # control のブロック
# 10.244.2.0/24 via 192.168.100.13 dev enp1s0   # worker2 のブロック
# ★ cilium_vxlan ではなく enp1s0 直接! autoDirectNodeRoutes によって
#   Cilium agent が直接プログラムしたルート (proto は kernel/cilium 由来で
#   Calico の "proto bird" のような BGP 由来のマークは付かない)

# カプセル化なしで Pod 間通信できることを確認
NGINX_W2=$(kubectl get pod -l app=nginx-ds -o wide | grep worker2 | awk '{print $6}')
kubectl exec debug -- ping -c3 $NGINX_W2

# キャプチャで内側パケットがそのまま流れることを確認 (UDP/8472 のラップが消える)
ssh ubuntu@worker1 "sudo tcpdump -i enp1s0 -n 'dst $NGINX_W2' -v -c5"
# Pod IP がそのまま見えるはず (カプセル化されていないので宛先がそのまま Pod IP)
```

**ポイント**: ネイティブルーティングではカプセル化オーバーヘッドがゼロになり、MTU 問題も
発生しない。Calico の BGP モード (2.7) と得られる結果 (カプセル化なしの直接ルーティング)
は同じだが、実現方法が異なる: Calico は Bird が本物の BGP プロトコルでルートを配布する
のに対し、Cilium の `autoDirectNodeRoutes` は同一 L2 セグメントであることを前提に
Cilium agent が Kubernetes API の情報から直接ルートを書き込むだけで、BGP セッションは
張らない。Cilium にも物理ルーター/スイッチと本物の BGP ピアリングを行う BGP Control
Plane 機能 (`CiliumBGPClusterConfig` 等) は別途あるが、本ラボの L2 構成では不要なため
扱わない。

### iperf3 で再計測 (ネイティブルーティング経由)

3.6 で使った `iperf3-server-w2` / `iperf3-client` はそのまま残っているので、Pod を
作り直さずにモード切り替えの影響だけを計測できる:

```bash
kubectl exec iperf3-client -- iperf3 -c $IPERF_W2 -t 5
# [ ID] Interval           Transfer     Bitrate         Retr
# [  5]   0.00-5.00   sec   ... MBytes  ... Mbits/sec    x    sender
# VXLAN のカプセル化/デカプセル化が無くなった状態の値。3.6 の結果と見比べる

kubectl exec debug -- ping -c 20 -q $IPERF_W2 | tail -3
# rtt min/avg/max/mdev = ... ms
# 3.6 (VXLAN) の平均 RTT と比較する
```

**ポイント**: このラボの物理 NIC は 1GbE のため、スループット自体は NIC がボトルネックに
なり VXLAN/ネイティブの差が誤差程度に収まることもある。差が出やすいのはむしろ

- **RTT** (VXLAN はパケットごとにカプセル化/デカプセル化の処理が挟まる分だけ増える)
- `iperf3` 出力の **Retr** (再送) 列 (MTU 1450 への分割で発生しやすい)
- ノードの CPU 使用率 (`ssh ubuntu@worker1 mpstat 1 3` などでカプセル化処理のコストを見る)

の3点。10GbE 以上の環境ではスループット自体の差もより顕著に出やすい。

計測用 Pod を片付ける:

```bash
kubectl delete pod iperf3-client iperf3-server-w2 --ignore-not-found
```

---

## 3.8 iptables が(ほぼ)使われていないことを確認

Flannel (kube-proxy + iptables, 1.7) や Calico (同じく iptables, 2.8) と異なり、Cilium は
kube-proxy 置き換えモードのため Service 転送も含めてほぼ全ての処理を eBPF Map で行う。

```bash
ssh ubuntu@worker1 'sudo iptables -L -n | wc -l'
# 少ない行数 (kube-proxy 時代は数百〜数千ルールあった)

ssh ubuntu@worker1 'sudo iptables -L KUBE-SERVICES -n 2>/dev/null | wc -l'
# KUBE-SERVICES チェーンが存在しないか空
```

**比較** (参考値):
- kube-proxy + Flannel/Calico 時: ~500〜1000 iptables ルール
- Cilium KubeProxy Replacement 時: ~20〜50 ルール (最小限)

---

## 3.9 Service の通信経路 (kube-proxy 不使用、eBPF で転送)

Flannel (1.7) と Calico (2.8) では ClusterIP → Pod の変換を kube-proxy が
`KUBE-SERVICES → KUBE-SVC-xxx → KUBE-SEP-xxx` という iptables チェーンで行っていました。
Cilium はこの変換自体も eBPF Map (`cilium_lb4_services` 等) 上で完結させます。

```bash
kubectl get svc nginx-svc
# NAME        TYPE        CLUSTER-IP    PORT(S)
# nginx-svc   ClusterIP   10.96.x.y     80/TCP

CLUSTER_IP=$(kubectl get svc nginx-svc -o jsonpath='{.spec.clusterIP}')

# ClusterIP で curl (debug Pod から)
kubectl exec debug -- wget -qO- $CLUSTER_IP
```

### Cilium の Service テーブルを確認

```bash
CILIUM_POD=$(kubectl get pod -n kube-system -l k8s-app=cilium -o name | head -1)
kubectl exec -n kube-system $CILIUM_POD -- cilium service list | grep $CLUSTER_IP
# 10.96.x.y:80 nginx-svc/default ClusterIP  1 => 10.244.0.x:80 (active)
#                                                   10.244.1.y:80 (active)
#                                                   10.244.2.z:80 (active)
```

**まとめ**: DNAT が iptables の代わりに eBPF Map 上の Service テーブルで完結する点を
除けば、変換後の宛先 Pod IP への実際の転送は 3.5 (同一ノード) / 3.6 (ノードをまたぐ) と
まったく同じ経路に合流します。

---

## 3.10 L7 ネットワークポリシーを試す

Flannel (非対応) や Calico (L3/L4 のみ、2.9) と異なり、Cilium は HTTP メソッドや
パスレベルのポリシーまで踏み込めます。

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
```

**ポイント**: Flannel / Calico は L4 (ポート番号) までしか制御できませんが、
Cilium は HTTP メソッドやパスレベルで制御できます。これは 3.11 の Hubble でも
可視化できます (`hubble observe --type drop`)。

クリーンアップ:

```bash
kubectl delete ciliumnetworkpolicy httpbin-l7-policy
kubectl delete deployment httpbin
kubectl delete svc httpbin
```

---

## 3.11 Hubble で通信フローを観察する

Hubble は Cilium の可観測性プラットフォームです。eBPF フックを使って全 Pod の通信フローを記録します。
Flannel/Calico にはこれに相当する仕組みはありません。

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

## 3.12 Pod からインターネットへの疎通

Flannel/Calico は iptables の MASQUERADE で SNAT していましたが (1.8/2.10)、Cilium は
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

## 3.13 Cilium のまとめ

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

## 3.14 Cilium のアンインストール (CNI 未導入の状態に戻す)

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

# 5. 3.7 でネイティブルーティングモードに切り替えていた場合、Pod サブネット宛ての
#    直接ルート (dev enp1s0) が残る。これは cilium_vxlan 等とは違い物理 NIC 上の
#    ルートなのでインターフェース削除では消えない。次章の CNI と衝突しないよう明示的に削除する
#    (3.7 を試していなければ何もヒットせず無害)
for node in control worker1 worker2; do
  ssh ubuntu@$node 'sudo ip route show | grep "^10.244\..*dev enp1s0" | \
    while read -r route; do dst=$(echo "$route" | awk "{print \$1}"); sudo ip route del "$dst" dev enp1s0; done; true'
done

# 6. CNI 設定ファイルを削除
for node in control worker1 worker2; do
  ssh ubuntu@$node 'sudo rm -f /etc/cni/net.d/*.conf /etc/cni/net.d/*.conflist'
done

# 7. kube-proxy を復元 (3.1 で kubeProxyReplacement のために削除済みのため)
ssh ubuntu@control 'sudo kubeadm init phase addon kube-proxy'

# 8. CoreDNS を元の replica 数に戻す
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

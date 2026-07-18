# Step 4: 3 CNI の比較まとめ

JANOG57「今こそ学びたい Kubernetes ネットワーク」の内容を踏まえ、
Flannel / Calico / Cilium の特性を整理します。

---

## 4.1 機能比較表

| 項目                   | Flannel          | Calico              | Cilium                  |
|------------------------|------------------|---------------------|-------------------------|
| **データプレーン**      | Linux VXLAN      | iptables / eBPF     | eBPF (TC/XDP)           |
| **ノード間通信**        | VXLAN (UDP/8472) | IPIP / BGP / VXLAN  | VXLAN / Native Routing  |
| **カプセル化**          | VXLAN (常に)     | IPIP / VXLAN / なし | VXLAN / Geneve / なし   |
| **ルート配布**          | etcd / K8s API   | BGP (Bird)          | BGP (GoBGP)             |
| **L3/L4 ネットワークポリシー** | ✗          | ✅                  | ✅                      |
| **L7 ネットワークポリシー**    | ✗          | ✗                   | ✅ (HTTP/gRPC/Kafka)    |
| **kube-proxy 置き換え** | ✗              | 部分的              | ✅ (完全置き換え)        |
| **可観測性**            | なし             | なし                | Hubble (フロー可視化)    |
| **物理 NW との統合**    | ✗              | ✅ (BGP ピアリング)  | ✅ (BGP ピアリング)      |
| **eBPF**                | ✗              | オプション          | ✅ (コア技術)            |
| **セットアップ難易度**  | 低              | 中                  | 中〜高                  |
| **本番導入事例**        | 多数             | 非常に多数           | 急増中                  |

---

## 4.2 ネットワークスタック比較

### Flannel: VXLAN オーバーレイ

```
Pod eth0
  │ veth pair
  ▼
cni0 (Linux Bridge)
  │
flannel.1 (VXLAN デバイス, VNI=1)
  │ UDP/8472 カプセル化
  ▼
enp1s0 (物理 NIC)
  │ 192.168.100.0/24 (ノード間)
  ▼
リモートノードの enp1s0
  │ VXLAN デカプセル
  ▼
flannel.1 → cni0 → Pod eth0
```

**特徴**:
- Bridge (cni0) を経由するため追加のホップが発生
- VXLAN で MTU が 50 バイト削減 (1500 → 1450)
- 設定が単純で壊れにくい

### Calico: BGP + ダイレクトルーティング

```
Pod eth0
  │ veth pair (cali...)
  ▼  ← ARP Proxy, Proxy ARP enabled
ノードのルーティングテーブル (Bird BGP が書く)
  │ 10.244.2.0/26 via 192.168.100.13 dev enp1s0
  ▼
enp1s0 (物理 NIC)
  │ 192.168.100.0/24 (ノード間, カプセル化なし)
  ▼
リモートノードの enp1s0
  │ ルーティングテーブルで直接 Pod へ
  ▼
Pod eth0
```

**特徴**:
- BGP ネイティブモードではカプセル化オーバーヘッドがゼロ
- 物理スイッチ/ルーターと BGP ピアリング可能
- `proto bird` でインストールされたルートが見える

### Cilium: eBPF データプレーン

```
Pod eth0
  │ veth pair (lxc...)
  ▼
TC eBPF hook (cil_from_container)
  │ eBPF Map でルーティング判断
  │ VXLAN or 直接転送
  ▼
enp1s0 (物理 NIC)
  │ XDP eBPF hook (最速パス)
  ▼
リモートノードの enp1s0
  │ TC eBPF hook (cil_to_container)
  ▼
Pod eth0
```

**特徴**:
- カーネル内で eBPF Map (O(1) 検索) で転送判断
- iptables の線形スキャンを排除
- conntrack も eBPF Map で実装 (kernel の conntrack バイパス可能)

---

## 4.3 同一ノード内 vs ノードをまたぐ通信の比較

01〜03 章でそれぞれ確認した通り、**3 つの CNI すべてが同一ノード内の Pod 間
通信ではカプセル化を避ける**という共通点があります。違いは「同一ノード内を
具体的にどう転送するか」という設計思想にあります。

| CNI     | 同一ノード内 (01.3 / 02.6 / 03.6)                      | ノードをまたぐ場合                        |
|---------|--------------------------------------------------------|--------------------------------------------|
| Flannel | `cni0` (Linux Bridge) で L2 スイッチング。カプセル化なし | VXLAN (`flannel.1`, UDP/8472)              |
| Calico  | Pod ごとの `/32` ホストルート + veth 直結。カプセル化なし | IPIP (`tunl0`) または BGP ネイティブルーティング |
| Cilium  | eBPF が送信元 veth (`lxc...`) から宛先 veth へ直接 redirect。カプセル化なし | VXLAN (`cilium_vxlan`, UDP/8472) または Native Routing |

**ポイント**: カプセル化のオーバーヘッド (MTU 削減や CPU コスト) が発生するのは
常に「ノードをまたぐ通信」だけです。同一ノード内で完結する通信が多いワーク
ロードほど、CNI の実装差 (ブリッジ / ルーティング / eBPF) の影響を受けにくいと
言えます。逆に言えば、**ノード間通信が多いワークロードほど CNI の選択がパフォー
マンスに直結する**ということでもあります。

---

## 4.4 ネットワークエンジニア視点での重要ポイント

### VXLAN vs IPIP vs BGP ネイティブ

| 方式          | オーバーヘッド | MTU       | キャプチャ       | 物理NW統合 |
|---------------|---------------|-----------|-----------------|-----------|
| VXLAN         | 50 bytes      | 1450      | UDP/8472 で見える | ✗         |
| IPIP          | 20 bytes      | 1480      | proto 4 で見える  | ✗         |
| BGP ネイティブ | 0 bytes       | 1500      | Pod IP がそのまま | ✅        |
| eBPF (Cilium) | 可変           | 可変      | Hubble で見る    | ✅        |

### アンダーレイとの関係

JANOG57 スライドが指摘する通り、**ネットワークチームとプラットフォームチームの対話**が重要です:

```
┌──────────────────────────────────────────┐
│  プラットフォームチーム                   │
│  - Pod CIDR の決定                        │
│  - CNI の選択                             │
│  - ネットワークポリシーの設計             │
└────────────────┬─────────────────────────┘
                 │ 対話が必要な点
                 │ ・BGP ピアリング先と AS 番号
                 │ ・Pod CIDR が既存 NW と重複しないか
                 │ ・MTU 設定 (ジャンボフレーム対応?)
                 │ ・NodePort の外部公開経路
                 ▼
┌──────────────────────────────────────────┐
│  ネットワークチーム                       │
│  - アンダーレイ (物理/仮想スイッチ)      │
│  - BGP ピアリング設定                    │
│  - MTU / VLAN 設計                       │
└──────────────────────────────────────────┘
```

#### Calico BGP でアンダーレイと統合する例

```
物理スイッチ (BGP ルーター, AS 65000)
    │
    ├── worker1 (Bird BGP, AS 64512) → 10.244.1.0/26 を広報
    ├── worker2 (Bird BGP, AS 64512) → 10.244.2.0/26 を広報
    └── worker3 (Bird BGP, AS 64512) → 10.244.3.0/26 を広報
```

このとき外部ルーターから Pod に直接ルーティング可能になります。

---

## 4.5 kube-proxy の進化

| 方式          | 実装           | Service 転送   | ルール数          |
|---------------|---------------|----------------|-------------------|
| iptables モード | iptables DNAT | 線形スキャン    | Service 数×Pod 数 |
| ipvs モード    | Linux IPVS    | ハッシュ (O(1)) | コンパクト         |
| Cilium eBPF   | eBPF Map      | ハッシュ (O(1)) | iptables ほぼ不使用 |

JANOG57 スライド「L4 ロードバランサー: kube-proxy」の内容:
- iptables は Service 数が増えると線形にスキャン時間が増加
- Cilium の eBPF Map はハッシュ引きなので O(1)

---

## 4.6 CNI 選択の指針

```
シンプルさ重視 / 学習・検証
  → Flannel

本番環境 / ネットワークポリシー必須 / 物理NWとBGP統合
  → Calico

マイクロサービス / 高可観測性 / L7ポリシー / 高パフォーマンス
  → Cilium

OSSに頼らず自社最適化 (JANOG57 スライド参照)
  → GKE Dataplane V2 (eBPF ベース)
  → Amazon VPC CNI (VPC ネイティブ)
  → Azure CNI
  → Cybozu Coil (BGP ベース自社実装)
```

---

## 4.7 このラボで確認したコマンド集

```bash
# ===== 共通 (同一ノード内 vs ノードをまたぐ の切り分け) =====
ip route get <宛先 Pod IP>              # 経路が bridge/veth 直結か、トンネルデバイス経由かを確認
tcpdump -i <物理NIC> -n icmp -c3        # 同一ノード内なら物理 NIC にはパケットが出ないはず

# ===== Flannel =====
ip -d link show flannel.1              # VXLAN デバイス
bridge fdb show dev flannel.1          # VTEP の FDB
ip route | grep flannel                # ルーティングテーブル
tcpdump -i cni0 -n icmp -c3            # 同一ノード内 (ブリッジ上でそのまま見える)
tcpdump -i enp1s0 udp port 8472        # VXLAN パケットキャプチャ (ノードをまたぐ場合)

# ===== Calico =====
ip route get <同一ノードの Pod IP>      # /32 ホストルート (veth 直結) を確認
ip route | grep bird                   # BGP が入れたルート (ノードをまたぐ場合)
ip -d link show tunl0                  # IPIP トンネル
tcpdump -i enp1s0 proto 4             # IPIP パケットキャプチャ
kubectl exec calico-node -- birdcl show protocols  # BGP ピア状態
kubectl get networkpolicy              # ネットワークポリシー一覧
iptables -L cali-FORWARD -n            # Calico の iptables ルール

# ===== Cilium =====
tcpdump -i cilium_vxlan -c3            # 同一ノード内 (トンネルにパケットが出ないことを確認)
tc filter show dev lxcXXXXXX ingress   # veth にアタッチされた eBPF プログラム
bpftool prog list | grep cil           # eBPF プログラム一覧
bpftool map list | grep cilium         # eBPF Map 一覧
cilium status                          # Cilium の状態
cilium service list                    # Service 一覧 (eBPF)
hubble observe --follow                # リアルタイムフロー
iptables-save | wc -l                  # iptables ルール数 (少ないはず)
```

---

## 4.8 参考リンク

- [Flannel GitHub](https://github.com/flannel-io/flannel)
- [Calico ドキュメント](https://docs.tigera.io/calico/latest/about/)
- [Cilium ドキュメント](https://docs.cilium.io/)
- [JANOG57 スライド「今こそ学びたい Kubernetes ネットワーク」](https://www.janog.gr.jp/meeting/janog57/)
- [Kubernetes Networking Model](https://kubernetes.io/docs/concepts/cluster-administration/networking/)
- [CNI specification](https://github.com/containernetworking/cni/blob/main/SPEC.md)

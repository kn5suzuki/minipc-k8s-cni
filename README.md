# Mini PC Kubernetes CNI ラボ

Ubuntu 24.04 を入れた Mini PC 上に KVM/libvirt で 3 台の VM (制御/ワーカー×2) を立て、
**kubeadm** で Kubernetes を構築し、CNI プラグイン **Flannel / Calico / Cilium** の動作を
ネットワークエンジニア視点で掘り下げるハンズオンです。


## 1. 基本構成

```
Mini PC host (Ubuntu 24.04, 16GB RAM, 4 core, KVM + libvirt)
├── control  (2 vCPU / 4 GB)  — kube-apiserver / etcd / scheduler / controller-manager
├── worker1  (2 vCPU / 3 GB)  — kubelet / kube-proxy / CNI agent
└── worker2  (2 vCPU / 3 GB)  — kubelet / kube-proxy / CNI agent
```

ネットワーク:

| 名前   | ブリッジ | サブネット           | 用途                            |
|--------|----------|----------------------|---------------------------------|
| k8s    | virbr10  | 192.168.100.0/24     | ノード間通信 / SSH / API        |

Pod / Service CIDR (kubeadm で指定):

| 用途         | CIDR              |
|--------------|-------------------|
| Pod ネットワーク | 10.244.0.0/16  |
| Service       | 10.96.0.0/12      |

| ホスト   | k8s IP (Node IP)    |
|----------|---------------------|
| control  | 192.168.100.11      |
| worker1  | 192.168.100.12      |
| worker2  | 192.168.100.13      |

## 2. 手順 (0 章の後ならどの章からでも進められます)

0. [00-setup.md](00-setup.md)             — ホスト準備 + VM 作成 + Kubernetes クラスタ構築 (`make cluster` でほぼ自動化)
1. [01-flannel.md](01-flannel.md) — Flannel (VXLAN オーバーレイ) を体験
2. [02-calico.md](02-calico.md)   — Calico (BGP/IPIP) とネットワークポリシーを体験
3. [03-cilium.md](03-cilium.md)   — Cilium (eBPF) と Hubble 可視化を体験
4. [04-comparison.md](04-comparison.md)   — 3 CNI の比較まとめ

このラボの本質は 1〜4 章の CNI 比較です。0 章 (ホスト準備〜クラスタ構築) は
`make cluster` 一発でほぼ自動化されています。0 章さえ終わっていれば 1〜3 章は
どの順番で読んでも構いません。各章は末尾で自身が入れた CNI を完全にアンイン
ストールし、0 章直後と同じ状態 (CNI 未導入、全 Node `NotReady`) に戻すため、
次にどの章を読んでも影響を受けません。4 章は 1〜3 章の内容を横断的に比較する
リファレンスです。

## 3. 学習ゴール (JANOG57 スライド対応)

| スライドの章              | 対応する手順                          |
|--------------------------|---------------------------------------|
| Kubernetes を知る         | Step 0: kubeadm でクラスタ構築       |
| Kubernetes とネットワーク  | Step 0: Pod / Service の概念確認      |
| Linux のネットワークスタック| Step 1〜3: veth / bridge / iptables 観察 |
| L2/L3 ネットワーク: CNI   | Step 1 (Flannel), 2 (Calico), 3 (Cilium) |
| L4 ロードバランサー        | Step 0〜3: kube-proxy / Cilium KP     |
| プラットフォームとの対話    | Step 4: 比較まとめ                    |

## 4. 前提と注意

- **メモリ**: 4 + 3 + 3 = 10 GB を VM に割り当てます。ホスト残 6 GB。
  16 GB がきつい場合は control 3 GB / worker 各 2 GB に減らしても動作します。
- **CPU**: VT-x/AMD-V 必須。
- 本手順は **学習・検証用途**。TLS 強化・RBAC・HA などは省略しています。
- 各 CNI 章は独立しています。切り替え時にクラスタを再構築する必要はなく、
  章ごとに「その章の CNI をアンインストールして 0 章直後の状態に戻す」手順を
  末尾に記載しています。

## 5. ディレクトリ構成

```
minipc-kubernetes/
├── README.md
├── 00-setup.md
├── 01-flannel.md
├── 02-calico.md
├── 03-cilium.md
├── 04-comparison.md
├── net/
│   └── k8s-mgmt-net.xml
├── cloud-init/
│   ├── user-data.tmpl
│   ├── network-config.tmpl
│   └── make-seed.sh
└── images/                    # cloud image / seed ISO 置き場
```

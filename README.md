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

## 3. 前提と注意

- **メモリ**: 4 + 3 + 3 = 10 GB を VM に割り当てます。ホスト残 6 GB。
  16 GB がきつい場合は control 3 GB / worker 各 2 GB に減らしても動作します。
- **CPU**: VT-x/AMD-V 必須。
- 本手順は **学習・検証用途**。TLS 強化・RBAC・HA などは省略しています。
- 各 CNI 章は独立しています。切り替え時にクラスタを再構築する必要はなく、
  章ごとに「その章の CNI をアンインストールして 0 章直後の状態に戻す」手順を
  末尾に記載しています。

## 4. ディレクトリ構成

```
minipc-kubernetes/
├── README.md               # このファイル (概要・手順の入り口)
├── CLAUDE.md                # Claude Code 向けのリポジトリ運用ルール
├── Makefile                  # VM構築〜CNI切り替えまで全操作の起点 (make help で一覧)
├── 00-setup.md               # 0章: ホスト準備 + make cluster でのクラスタ構築
├── 01-flannel.md             # 1章: Flannel (VXLANオーバーレイ) を体験
├── 02-calico.md              # 2章: Calico (BGP/IPIP) とネットワークポリシーを体験
├── 03-cilium.md              # 3章: Cilium (eBPF) と Hubble可視化を体験
├── 04-comparison.md          # 4章: 3 CNI の比較まとめ
├── net/
│   └── k8s-mgmt-net.xml     # libvirt 仮想ネットワーク定義 (virbr10, 192.168.100.0/24) — make nets が読む
├── cloud-init/
│   ├── user-data.tmpl        # 全ノード共通の cloud-init テンプレート
│   ├── network-config.tmpl   # ノードごとの固定IPアドレス設定テンプレート
│   └── make-seed.sh          # 上記2つをレンダリングし seed ISO を作るスクリプト (make seeds が呼ぶ)
├── scripts/
│   └── k8s-prereq.sh         # 全ノードに containerd + kubeadm/kubelet/kubectl を導入 (make k8s-prereq が SSH 経由で実行、VM にはコピーしない)
├── manifests/
│   └── nginx-ds.yaml         # 01〜03章で使い回すテスト用ワークロード (nginx DaemonSet + ClusterIP Service + debug Pod)
└── images/                   # cloud image / seed ISO の置き場 (make が生成。.gitignore 対象で Git 管理外)
```

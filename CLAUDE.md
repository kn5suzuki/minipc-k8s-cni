# CLAUDE.md

## このリポジトリについて

ミニ PC 上で実際に手を動かしながら Kubernetes の CNI を比較勉強するラボです。

`Makefile` が KVM/libvirt を操作して Mini PC ホスト (Ubuntu 24.04) 上に VM を3台構築し、それらに `kubeadm` クラスタを立ち上げることでベースの環境を構築し、その上に各 CNI プラグインをインストールします。

現在サポートしている CNI プラグインは Flannel / Calico / Cilium の 3 つです。
各 CNI プラグインについて、プラグインの仕組み、ノード内 Pod 間通信、ノード間 Pod 間通信、Pod からインターネットへの通信の仕組みを理解することを目的とし、各 CNI が Pod ネットワーク・Service・NetworkPolicy をパケットレベル (ルーティングテーブル、`tcpdump`、eBPF map など) でどう実装しているかを観察できるようにしています。

通常の意味でのビルド/lint/テスト対象となるアプリケーションコードはありません — ここでの「正しさ」とは、`make` の各ターゲットが期待通りクラスタを収束させ、各章に書かれた `tcpdump`/`ip route`/`bpftool` コマンドが説明通りの出力を返すことを指します。

番号付きの `.md` ファイルは、`00-setup.md` でクラスタを構築済みであれば `01`/`02`/`03` のどれからでも独立して進められるチュートリアルです。各章は「CNI 未導入の状態 (= `00-setup.md` 完了直後と同じ状態) から始まり、その章の CNI を入れて観察し、章末のアンインストール手順で再び CNI 未導入の状態に戻す」という同一構成を取ります (詳細は後述の「ドキュメント構成」を参照)。前の章を完了しているかどうかに関わらず、章の冒頭で前提 (CNI 未導入状態) を確認・復元してから進められます。

## Makefile

すべての操作は `Makefile` 経由か、VM への SSH (`ubuntu@control`, `ubuntu@worker1`, `ubuntu@worker2` — `/etc/hosts` で名前解決、詳細は `00-setup.md`) で行います。全ターゲットの一覧は `make help` で確認できます。

```bash
make cluster        # VM構築 -> kubeadmクラスタ構築まで、CNIはまだ未導入 (nets -> seeds -> vms -> wait-vms -> k8s-prereq -> k8s-init -> k8s-join の順に連鎖実行)
make flannel        # Flannel をインストール (先に `uninstall` が走るので、どの状態からでも導入可能)
make calico         # Calico をインストール
make cilium         # Cilium をインストール
make uninstall      # 導入済みの CNI を何であれ削除し、kube-proxy アドオンを復元する
make status         # VM / libvirt ネットワーク / ノード / Pod の状態を一括表示
make reset          # make clean && make cluster (フル再構築)
make clean          # VM・libvirt ネットワーク・seed ISO を削除 (破壊的操作)
```

一連の流れの一部だけ実行したい場合は、より細かいターゲットも用意されています: `nets`, `seeds`, `vms`, `wait-vms`, `k8s-prereq`, `k8s-init`, `k8s-join`, `clean-vms`, `clean-nets`, `clean-seeds`。

`flannel`/`calico`/`cilium` は意図的に**順序に依存しない**設計です — それぞれが依存するのは `uninstall` のみで、互いには依存していません。`uninstall` を変更する際はこの性質を壊さないこと: 直前に入っていた CNI が行ったことを完全に元に戻す必要があります (例: Cilium の `kubeProxyReplacement` は `kube-proxy` DaemonSet を削除するため、`uninstall` は `kubeadm init phase addon kube-proxy` でこれを復元し、さらに `flannel.1`/`cni0`/`tunl0`/`cilium_vxlan`/`cilium_host`/`cilium_net` といった CNI 固有のインターフェースを全ノードから削除します)。

CI は存在しません。変更を検証するには、実際の VM に対して該当する `make` ターゲットを実行する (最低限でも SSH/kubectl コマンドの流れを手で追って確認する) 必要があります。これはテストスイートを持つコードではなく、インフラ自動化だからです。

## アーキテクチャ

### トポロジー (固定値、ドキュメント全体で参照される)

- ホスト: Mini PC、KVM/libvirt、`virbr10` ブリッジ、ネットワーク `192.168.100.0/24` (`net/k8s-mgmt-net.xml`、DHCP の host 予約で MAC -> ホスト名 -> IP を固定)
- `control` = `192.168.100.11` (control-plane)、`worker1` = `.12`、`worker2` = `.13`
- Pod CIDR `10.244.0.0/16`、Service CIDR `10.96.0.0/12`、kubeadm/kubelet/kubectl は v1.31 に固定 (`pkgs.k8s.io/core:/stable:/v1.31`)、ベースイメージは Ubuntu 24.04 (noble)

### プロビジョニングの流れ

1. `cloud-init/user-data.tmpl` と `network-config.tmpl` はノードごとのテンプレート。`cloud-init/make-seed.sh <hostname>` がこれらをレンダリングし、ノードごとの seed ISO を作成する (`make seeds`)。
2. `make vms` は Ubuntu の cloud image を一度だけダウンロードし、それと各ノードの seed ISO を使って `qemu-img`/`virt-install` で3台の VM を作成する。
3. `make wait-vms` は各ノードで SSH が通ることに加え、`cloud-init status --wait` の完了も待つ — この2段階目の待機が必要な理由は、cloud-init 自身の `packages:` による apt 実行が、sshd が接続を受け付け始めた後もまだ apt のロックを保持していることがあり、以前 `k8s-prereq` の `apt update` とここで競合していたため。
4. `scripts/k8s-prereq.sh` (VM にコピーせず SSH 経由で実行) が全3ノードに containerd + kubeadm/kubelet/kubectl を導入する。
5. `k8s-init` が `control` で `kubeadm init` を実行し、kubeconfig をホスト側の `~/.kube/k8s-lab.config` に保存する。`k8s-join` が2台の worker を参加させる。

### CNI の切り替え

`uninstall` は現在導入されている CNI の痕跡 (manifest・Helm release・CRD・ノード上のインターフェース・CNI 設定ファイル) をすべて取り除き、新しい CNI を入れる前に必ず実行される — これにより `flannel`/`calico`/`cilium` はどんな順序でも、まっさらなクラスタからでも安全に実行できる。各 CNI の章の `.md` ファイル内にある「アンインストール」節は学習目的で同じ手順を手動で示しているが、実際の仕組みは `make uninstall` である。この「アンインストール」節はどの章でも同じベースライン (CNI 未導入・全ノード `NotReady`) に収束させるものであり、これが 01/02/03 章を互いに独立させている根拠になっている。

`manifests/nginx-ds.yaml` (nginx DaemonSet + ClusterIP Service + `debug` という busybox Pod) は3つの CNI の章すべてで同一のまま使い回すテスト用ワークロードであり、これにより挙動を公平に比較できる。

### ドキュメント構成と番号付けの規則

- `00-setup.md` — ホスト準備 (手動・最初の一度だけ) と、メインの手順である `make cluster`。旧来の手動 VM/kubeadm 構築手順は参考用の付録 (0.3節) として残してあり、メインフローではない。
- `01-flannel.md`, `02-calico.md`, `03-cilium.md` — CNI ごとに1章。どの章も同じ構成: 前提の確認 (CNI 未導入の状態であることを保証。導入済みなら `make uninstall` 相当の手順を先に実行) -> インストール -> 同一ノード内の Pod間通信 (カプセル化なし) -> ノードをまたぐ Pod間通信 (CNI 固有のカプセル化/ルーティング) -> Service 経路 -> Pod からインターネットへ (SNAT) -> 対応していれば NetworkPolicy -> まとめの表 -> アンインストール (章が入れたものを完全に元に戻し、CNI 未導入の状態に復元する。次章への引き継ぎ事項は残さない)。
- `04-comparison.md` — CNI 横断のまとめ。同一ノード内 vs ノードをまたぐ通信の比較表を含む。
- **見出し番号は章 (ファイル) 番号と一致させている** (`02-calico.md` なら `## 2.1`, `## 2.2`, ...)。各章はこの見出しから生成される GitHub 形式のアンカーで互いにリンクしている (例: `01-flannel.md#110-flannel-...`)。これらのファイルで章の並び替え・リネーム・セクション挿入を行う場合は、そのファイル内の後続見出しをすべて振り直し、かつそこを指している章をまたぐアンカー/文中の参照もすべて修正する必要がある (「次の 2.7 で確認する」のような同一ファイル内の自己参照も、ファイルをまたぐリンクと同様に存在する) — このリポジトリには自動リンクチェッカーが無いため、これまでは手作業・grep で確認してきた。

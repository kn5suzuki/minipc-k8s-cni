# Step 0: ラボ環境のセットアップ

このラボの本質は 01〜04 章の **CNI の挙動を観察・比較すること** です。
この章はそこにたどり着くための土台 (ホスト準備 + VM 作成 + Kubernetes クラスタ構築)
であり、`make cluster` 一発でほぼ自動化されています。中身を理解したい場合や
トラブルシュートしたい場合のために、0.3 に手動での詳細手順も残してあります。

---

## 0.1 ホストの準備 (Mini PC, 最初に一度だけ)

Mini PC 上で実施。すべての操作はホストのシェルで `sudo` 可能なユーザで行います。

### パッケージ更新と必要ツール

```bash
sudo apt update && sudo apt -y full-upgrade

sudo apt install -y \
  qemu-system-x86 libvirt-daemon-system libvirt-clients \
  virtinst virt-manager bridge-utils cpu-checker \
  cloud-image-utils genisoimage \
  uuid-runtime jq curl wget git
```

### KVM 利用可否の確認

```bash
egrep -c '(vmx|svm)' /proc/cpuinfo    # 0 より大きいこと
sudo kvm-ok                            # "KVM acceleration can be used"
```

### libvirt 権限とデーモン起動

```bash
sudo systemctl enable --now libvirtd

sudo usermod -aG libvirt,kvm "$USER"

# グループを即時反映 (またはログアウト→再ログイン)
newgrp libvirt

echo 'export LIBVIRT_DEFAULT_URI=qemu:///system' >> ~/.bashrc
source ~/.bashrc

virsh uri    # "qemu:///system" と表示されること
```

### ホストのスワップを 8 GB 確保

```bash
sudo fallocate -l 8G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
free -h
```

### /etc/hosts に Node 名を登録

`make` 経由の SSH (`ssh ubuntu@control` など) がホスト名で疎通できるように、
ホスト自身の `/etc/hosts` にも登録しておきます。

```bash
sudo tee -a /etc/hosts <<'EOF'

# Kubernetes lab
192.168.100.11  control
192.168.100.12  worker1
192.168.100.13  worker2
EOF
```

> **注**: 仮想ネットワーク (`k8s` ブリッジ, `net/k8s-mgmt-net.xml`) とストレージ
> プール (`/var/lib/libvirt/images/k8s-lab`) は、この後の `make cluster`
> (内部で `make nets`) が自動的に作成します。ここで手動で作る必要はありません。

---

## 0.2 VM 作成 + Kubernetes クラスタ構築 (`make cluster`)

```bash
cd ~/repos/minipc-kubernetes
make cluster
```

これ1コマンドで以下がすべて実行されます:

| 内部で実行される make target | 内容 |
|---|---|
| `nets`     | 仮想ネットワーク (`k8s` = `virbr10`, 192.168.100.0/24) を作成 |
| `seeds`    | cloud-init seed ISO を control/worker1/worker2 分作成 |
| `vms`      | Ubuntu 24.04 cloud image から 3 台の VM を作成・起動 |
| `wait-vms` | 全 VM が SSH を受け付け、cloud-init が完了するまで待機 |
| `k8s-prereq` | 全ノードに containerd + kubeadm/kubelet/kubectl を導入 |
| `k8s-init` | control で `kubeadm init` を実行し、kubeconfig を `~/.kube/k8s-lab.config` に保存 |
| `k8s-join` | worker1/worker2 を `kubeadm join` でクラスタに参加させる |

完了確認:

```bash
export KUBECONFIG=~/.kube/k8s-lab.config
kubectl get nodes
# NAME      STATUS     ROLES           VERSION
# control   NotReady   control-plane   v1.31.x
# worker1   NotReady   <none>          v1.31.x
# worker2   NotReady   <none>          v1.31.x
# (CNI がまだないため全ノード NotReady が正常)
```

### Kubernetes の基本リソースを確認

CNI を入れる前に、Pod / Service の概念を軽く確認しておきます。

```bash
# system Pod の確認
kubectl get pods -n kube-system -o wide
# coredns は Pending のまま (CNI 未設定)

# Service の確認 (kube-proxy が作る ClusterIP)
kubectl get svc -A

# Node の情報
kubectl describe node control | grep -A5 'Conditions'
# NetworkUnavailable=True: CNI がないため
```

### kube-proxy の仕組みを確認

kube-proxy は Service の ClusterIP → Pod への L4 ロードバランスを担います。

```bash
# kube-proxy の DaemonSet 確認
kubectl get daemonset -n kube-system kube-proxy

# kube-proxy が書き込む iptables ルールを確認 (CNI インストール後に再確認)
ssh ubuntu@worker1 'sudo iptables -t nat -L KUBE-SERVICES -n --line-numbers | head -20'
```

---

## 0.3 (参考) 手動で理解したい場合: `make cluster` の中身

`make cluster` が何をしているか手を動かして理解したい場合、
あるいは途中で失敗してトラブルシュートしたい場合の詳細手順です。
普段はここを読む必要はありません。

### Cloud image のダウンロード

```bash
cd ~/repos/minipc-kubernetes
mkdir -p images
wget -O images/noble-server.img \
  https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
```

### SSH 鍵の用意 (なければ)

```bash
[ -f ~/.ssh/id_ed25519 ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
```

### seed ISO を作成

```bash
chmod +x cloud-init/make-seed.sh
./cloud-init/make-seed.sh control
./cloud-init/make-seed.sh worker1
./cloud-init/make-seed.sh worker2
```

### イメージを libvirt 管理下に配置

```bash
sudo mv images/noble-server.img /var/lib/libvirt/images/k8s-lab/

sudo cp images/control-seed.iso /var/lib/libvirt/images/k8s-lab/
sudo cp images/worker1-seed.iso  /var/lib/libvirt/images/k8s-lab/
sudo cp images/worker2-seed.iso  /var/lib/libvirt/images/k8s-lab/
```

### control / worker1 / worker2 VM を作成

```bash
# control
sudo qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/k8s-lab/noble-server.img \
  /var/lib/libvirt/images/k8s-lab/control.qcow2 30G

sudo virt-install \
  --name control \
  --vcpus 2 --memory 4096 \
  --cpu host-passthrough \
  --machine q35 \
  --os-variant ubuntu24.04 \
  --disk path=/var/lib/libvirt/images/k8s-lab/control.qcow2,format=qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/k8s-lab/control-seed.iso,device=cdrom \
  --network network=k8s,model=virtio,mac=52:54:00:01:00:01 \
  --graphics none \
  --console pty,target_type=serial \
  --import \
  --noautoconsole

# worker1
sudo qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/k8s-lab/noble-server.img \
  /var/lib/libvirt/images/k8s-lab/worker1.qcow2 30G

sudo virt-install \
  --name worker1 \
  --vcpus 2 --memory 3072 \
  --cpu host-passthrough \
  --machine q35 \
  --os-variant ubuntu24.04 \
  --disk path=/var/lib/libvirt/images/k8s-lab/worker1.qcow2,format=qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/k8s-lab/worker1-seed.iso,device=cdrom \
  --network network=k8s,model=virtio,mac=52:54:00:01:00:02 \
  --graphics none \
  --console pty,target_type=serial \
  --import \
  --noautoconsole

# worker2
sudo qemu-img create -f qcow2 -F qcow2 \
  -b /var/lib/libvirt/images/k8s-lab/noble-server.img \
  /var/lib/libvirt/images/k8s-lab/worker2.qcow2 30G

sudo virt-install \
  --name worker2 \
  --vcpus 2 --memory 3072 \
  --cpu host-passthrough \
  --machine q35 \
  --os-variant ubuntu24.04 \
  --disk path=/var/lib/libvirt/images/k8s-lab/worker2.qcow2,format=qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/k8s-lab/worker2-seed.iso,device=cdrom \
  --network network=k8s,model=virtio,mac=52:54:00:01:00:03 \
  --graphics none \
  --console pty,target_type=serial \
  --import \
  --noautoconsole
```

### 起動・疎通確認

cloud-init 完了まで 1〜2 分待ちます。

```bash
virsh list --all
# control / worker1 / worker2 が running であること

# SSH 接続確認
ssh ubuntu@control 'hostname; ip -br addr; uname -r'
ssh ubuntu@worker1 'hostname; ip -br addr'
ssh ubuntu@worker2 'hostname; ip -br addr'

# NTP 同期確認
ssh ubuntu@control 'chronyc sources'
ssh ubuntu@worker1 'chronyc sources'   # control が ^* になっていること
```

### スワップが無効になっていることを確認

Kubernetes は swap を嫌うため、cloud-init で無効化済みです。

```bash
ssh ubuntu@control 'free -h | grep Swap'
ssh ubuntu@worker1 'free -h | grep Swap'
ssh ubuntu@worker2 'free -h | grep Swap'
# Swap: 0 であること
```

### カーネルモジュールと sysctl の確認

```bash
ssh ubuntu@control 'lsmod | grep -E "overlay|br_netfilter"'
ssh ubuntu@control 'sysctl net.ipv4.ip_forward net.bridge.bridge-nf-call-iptables'
# net.ipv4.ip_forward = 1
# net.bridge.bridge-nf-call-iptables = 1
```

### containerd のインストール (全ノード)

```bash
for node in control worker1 worker2; do
  ssh ubuntu@$node 'bash -s' <<'ENDSSH'
    sudo install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    sudo chmod a+r /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
      https://download.docker.com/linux/ubuntu \
      $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list
    sudo apt update && sudo apt install -y containerd.io
    sudo mkdir -p /etc/containerd
    containerd config default | sudo tee /etc/containerd/config.toml
    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
    sudo systemctl restart containerd
    sudo systemctl enable containerd
ENDSSH
done
```

### kubeadm / kubelet / kubectl のインストール (全ノード)

```bash
for node in control worker1 worker2; do
  ssh ubuntu@$node 'bash -s' <<'ENDSSH'
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
      | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' \
      | sudo tee /etc/apt/sources.list.d/kubernetes.list
    sudo apt update
    sudo apt install -y kubelet kubeadm kubectl
    sudo apt-mark hold kubelet kubeadm kubectl
    sudo systemctl enable kubelet
ENDSSH
done
```

バージョン確認:

```bash
ssh ubuntu@control 'kubeadm version && kubectl version --client'
```

### クラスタの初期化 (control のみ)

```bash
ssh ubuntu@control

# control ノード上で実行
sudo kubeadm init \
  --apiserver-advertise-address=192.168.100.11 \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --node-name=control

# 成功すると末尾に worker 参加コマンドが表示される
# 例: kubeadm join 192.168.100.11:6443 --token ... --discovery-token-ca-cert-hash sha256:...
# このコマンドをメモしておく
```

kubectl を使えるようにする:

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# 確認
kubectl get nodes
# NAME      STATUS     ROLES           AGE   VERSION
# control   NotReady   control-plane   ...   v1.31.x
# (CNI がまだないため NotReady)
```

ホスト側でも kubectl を使えるようにする (任意):

```bash
# ホストで実行
mkdir -p ~/.kube
scp ubuntu@control:~/.kube/config ~/.kube/config
sed -i 's/127.0.0.1/192.168.100.11/' ~/.kube/config
kubectl get nodes
```

### Worker ノードをクラスタに参加させる

kubeadm init の出力に表示された `kubeadm join` コマンドを各 worker で実行します。

```bash
# worker1 で実行
ssh ubuntu@worker1
sudo kubeadm join 192.168.100.11:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --node-name=worker1

# worker2 で実行
ssh ubuntu@worker2
sudo kubeadm join 192.168.100.11:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --node-name=worker2
```

> **join トークンを忘れた場合**: control で `sudo kubeadm token create --print-join-command`

control からノード一覧を確認:

```bash
# control または ホストで
kubectl get nodes -o wide
# NAME      STATUS     ROLES           VERSION   INTERNAL-IP      ...
# control   NotReady   control-plane   v1.31.x   192.168.100.11
# worker1   NotReady   <none>          v1.31.x   192.168.100.12
# worker2   NotReady   <none>          v1.31.x   192.168.100.13
# (CNI がないため全ノード NotReady)
```

---

これで Kubernetes の骨格が出来ました。次は CNI プラグインを入れます。

- CNI を入れると Node が **Ready** になり、CoreDNS Pod が **Running** になります。
- [01-flannel.md](01-flannel.md)・[02-calico.md](02-calico.md)・[03-cilium.md](03-cilium.md)
  はそれぞれ独立しているので、どれから始めても構いません。まずは
  **[01-flannel.md](01-flannel.md)** から順に読むのがおすすめです。

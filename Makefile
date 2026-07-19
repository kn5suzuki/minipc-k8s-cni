LIBVIRT_DIR := /var/lib/libvirt/images/k8s-lab
NOBLE_IMG   := $(LIBVIRT_DIR)/noble-server.img
NOBLE_URL   := https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

SSH := ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null
SCP := scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null

NODES := control worker1 worker2

.PHONY: all cluster nets seeds vms reset status \
        wait-vms k8s-prereq k8s-init k8s-join \
        flannel calico cilium uninstall \
        clean clean-vms clean-nets clean-seeds help

## デフォルト: ネットワーク → seed ISO → VM を順に作成
all: nets seeds vms

## VM 作成から kubeadm join まで一気通貫 (02 + 03 章を1コマンドで)
cluster: all k8s-join
	@echo ">>> Kubernetes クラスタが起動しました (CNI 未導入, Node は NotReady のはず)。"
	@echo ">>> 次は CNI を入れます: make flannel / calico / cilium"

## 全削除してから make cluster 相当まで再構築
reset: clean cluster

# ─── ネットワーク ──────────────────────────────────────────────────────────────

nets:
	virsh net-destroy default  2>/dev/null || true
	virsh net-undefine default 2>/dev/null || true
	virsh net-info k8s >/dev/null 2>&1 || virsh net-define net/k8s-mgmt-net.xml
	virsh net-autostart k8s
	virsh net-start k8s 2>/dev/null || true

# ─── ベースイメージ ────────────────────────────────────────────────────────────

$(LIBVIRT_DIR):
	sudo mkdir -p $(LIBVIRT_DIR)
	sudo chown libvirt-qemu:libvirt $(LIBVIRT_DIR)

$(NOBLE_IMG): | $(LIBVIRT_DIR)
	@if [ -f images/noble-server.img ]; then \
	  echo ">>> images/noble-server.img を $(NOBLE_IMG) へ移動"; \
	  sudo mv images/noble-server.img $(NOBLE_IMG); \
	else \
	  mkdir -p images; \
	  wget -O images/noble-server.img $(NOBLE_URL); \
	  sudo mv images/noble-server.img $(NOBLE_IMG); \
	fi

# ─── seed ISO ─────────────────────────────────────────────────────────────────

images/control-seed.iso: cloud-init/make-seed.sh cloud-init/user-data.tmpl cloud-init/network-config.tmpl
	mkdir -p images
	bash cloud-init/make-seed.sh control

images/worker1-seed.iso: cloud-init/make-seed.sh cloud-init/user-data.tmpl cloud-init/network-config.tmpl
	mkdir -p images
	bash cloud-init/make-seed.sh worker1

images/worker2-seed.iso: cloud-init/make-seed.sh cloud-init/user-data.tmpl cloud-init/network-config.tmpl
	mkdir -p images
	bash cloud-init/make-seed.sh worker2

seeds: images/control-seed.iso images/worker1-seed.iso images/worker2-seed.iso

# ─── VM 作成 ──────────────────────────────────────────────────────────────────

vms: nets seeds $(NOBLE_IMG)
	sudo cp images/control-seed.iso $(LIBVIRT_DIR)/
	sudo cp images/worker1-seed.iso  $(LIBVIRT_DIR)/
	sudo cp images/worker2-seed.iso  $(LIBVIRT_DIR)/
	# control
	sudo qemu-img create -f qcow2 -F qcow2 \
	  -b $(NOBLE_IMG) $(LIBVIRT_DIR)/control.qcow2 30G
	sudo virt-install \
	  --name control \
	  --vcpus 2 --memory 4096 \
	  --cpu host-passthrough \
	  --machine q35 \
	  --os-variant ubuntu24.04 \
	  --disk path=$(LIBVIRT_DIR)/control.qcow2,format=qcow2,bus=virtio \
	  --disk path=$(LIBVIRT_DIR)/control-seed.iso,device=cdrom \
	  --network network=k8s,model=virtio,mac=52:54:00:01:00:01 \
	  --graphics none --console pty,target_type=serial \
	  --import --noautoconsole
	# worker1
	sudo qemu-img create -f qcow2 -F qcow2 \
	  -b $(NOBLE_IMG) $(LIBVIRT_DIR)/worker1.qcow2 30G
	sudo virt-install \
	  --name worker1 \
	  --vcpus 2 --memory 3072 \
	  --cpu host-passthrough \
	  --machine q35 \
	  --os-variant ubuntu24.04 \
	  --disk path=$(LIBVIRT_DIR)/worker1.qcow2,format=qcow2,bus=virtio \
	  --disk path=$(LIBVIRT_DIR)/worker1-seed.iso,device=cdrom \
	  --network network=k8s,model=virtio,mac=52:54:00:01:00:02 \
	  --graphics none --console pty,target_type=serial \
	  --import --noautoconsole
	# worker2
	sudo qemu-img create -f qcow2 -F qcow2 \
	  -b $(NOBLE_IMG) $(LIBVIRT_DIR)/worker2.qcow2 30G
	sudo virt-install \
	  --name worker2 \
	  --vcpus 2 --memory 3072 \
	  --cpu host-passthrough \
	  --machine q35 \
	  --os-variant ubuntu24.04 \
	  --disk path=$(LIBVIRT_DIR)/worker2.qcow2,format=qcow2,bus=virtio \
	  --disk path=$(LIBVIRT_DIR)/worker2-seed.iso,device=cdrom \
	  --network network=k8s,model=virtio,mac=52:54:00:01:00:03 \
	  --graphics none --console pty,target_type=serial \
	  --import --noautoconsole

# ─── SSH 待機 ─────────────────────────────────────────────────────────────────

wait-vms:
	@echo ">>> Waiting for VMs to accept SSH..."
	@for node in $(NODES); do \
	  echo -n "  waiting $$node..."; \
	  until $(SSH) -o ConnectTimeout=5 -o BatchMode=yes ubuntu@$$node true 2>/dev/null; \
	    do sleep 5; printf "."; done; \
	  echo " OK"; \
	done
	@echo ">>> Waiting for cloud-init to finish (package install etc.)..."
	@for node in $(NODES); do \
	  echo -n "  cloud-init $$node..."; \
	  $(SSH) ubuntu@$$node 'sudo cloud-init status --wait' >/dev/null 2>&1; \
	  echo " done"; \
	done

# ─── Kubernetes セットアップ ──────────────────────────────────────────────────

k8s-prereq: wait-vms
	@echo ">>> Installing containerd + kubeadm on all nodes..."
	@for node in $(NODES); do \
	  echo "  === $$node ==="; \
	  $(SSH) ubuntu@$$node 'bash -s' < scripts/k8s-prereq.sh; \
	done

k8s-init: k8s-prereq
	@echo ">>> Initializing Kubernetes control plane on control..."
	$(SSH) ubuntu@control 'sudo kubeadm init \
	  --apiserver-advertise-address=192.168.100.11 \
	  --pod-network-cidr=10.244.0.0/16 \
	  --service-cidr=10.96.0.0/12 \
	  --node-name=control 2>&1 | tee /tmp/kubeadm-init.log'
	$(SSH) ubuntu@control 'mkdir -p $$HOME/.kube && \
	  sudo cp /etc/kubernetes/admin.conf $$HOME/.kube/config && \
	  sudo chown $$(id -u):$$(id -g) $$HOME/.kube/config'
	@echo ">>> Copying kubeconfig to host..."
	mkdir -p ~/.kube
	$(SCP) ubuntu@control:~/.kube/config ~/.kube/k8s-lab.config
	@echo ">>> Merging into ~/.kube/config so plain 'kubectl' also works..."
	@touch ~/.kube/config
	@KUBECONFIG=~/.kube/config:~/.kube/k8s-lab.config kubectl config view --flatten > ~/.kube/config.new
	@mv ~/.kube/config.new ~/.kube/config
	@chmod 600 ~/.kube/config
	@KUBECONFIG=~/.kube/config kubectl config use-context kubernetes-admin@kubernetes >/dev/null
	@echo ">>> kubeconfig saved to ~/.kube/k8s-lab.config and merged into ~/.kube/config (current-context set to this cluster)"

k8s-join: k8s-init
	@echo ">>> Joining worker nodes..."
	@JOIN_CMD=$$($(SSH) ubuntu@control 'sudo kubeadm token create --print-join-command'); \
	for node in worker1 worker2; do \
	  echo "  joining $$node..."; \
	  $(SSH) ubuntu@$$node "sudo $$JOIN_CMD --node-name=$$node"; \
	done
	@echo ">>> Cluster nodes:"
	@$(SSH) ubuntu@control 'kubectl get nodes -o wide'

# ─── CNI インストール ─────────────────────────────────────────────────────────

uninstall:
	@echo ">>> Removing existing CNI (flannel / calico / cilium)..."
	$(SSH) ubuntu@control 'kubectl delete -f \
	  https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml \
	  2>/dev/null || true'
	$(SSH) ubuntu@control 'kubectl delete ns calico-system calico-apiserver tigera-operator 2>/dev/null || true; \
	  kubectl get crds 2>/dev/null | grep -E "calico|tigera" | awk "{print \$$1}" | \
	  xargs kubectl delete crd 2>/dev/null || true'
	$(SSH) ubuntu@control 'helm uninstall cilium -n kube-system 2>/dev/null || true'
	@for node in $(NODES); do \
	  $(SSH) ubuntu@$$node 'sudo ip link delete flannel.1 2>/dev/null; \
	    sudo ip link delete cni0 2>/dev/null; \
	    sudo ip link delete tunl0 2>/dev/null; \
	    sudo ip link delete cilium_vxlan 2>/dev/null; \
	    sudo ip link delete cilium_host 2>/dev/null; \
	    sudo ip link delete cilium_net 2>/dev/null; \
	    sudo rm -f /etc/cni/net.d/*.conf /etc/cni/net.d/*.conflist; \
	    true'; \
	done
	@echo ">>> Restoring kube-proxy addon (Cilium's kubeProxyReplacement removes it)..."
	$(SSH) ubuntu@control 'sudo kubeadm init phase addon kube-proxy 2>/dev/null || true'
	@echo ">>> CNI removed. Nodes may show NotReady briefly."

flannel: uninstall
	@echo ">>> Installing Flannel..."
	$(SSH) ubuntu@control 'kubectl apply -f \
	  https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml'
	$(SSH) ubuntu@control 'kubectl rollout status daemonset/kube-flannel-ds -n kube-flannel --timeout=120s'
	$(SSH) ubuntu@control 'kubectl get nodes'

calico: uninstall
	@echo ">>> Installing Calico (Operator)..."
	$(SSH) ubuntu@control 'kubectl create -f \
	  https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml'
	$(SSH) ubuntu@control 'kubectl apply -f - <<EOF\n\
apiVersion: operator.tigera.io/v1\n\
kind: Installation\n\
metadata:\n\
  name: default\n\
spec:\n\
  calicoNetwork:\n\
    ipPools:\n\
    - name: default-ipv4-ippool\n\
      cidr: 10.244.0.0/16\n\
      encapsulation: IPIP\n\
      natOutgoing: Enabled\n\
      nodeSelector: all()\n\
EOF'
	@echo ">>> Installing APIServer CR (needed to later modify IPPools, e.g. IPIP -> BGP native)..."
	$(SSH) ubuntu@control 'kubectl apply -f - <<EOF\n\
apiVersion: operator.tigera.io/v1\n\
kind: APIServer\n\
metadata:\n\
  name: default\n\
spec: {}\n\
EOF'
	@echo ">>> Waiting for calico-node DaemonSet (up to 3 min)..."
	$(SSH) ubuntu@control 'kubectl rollout status daemonset/calico-node -n calico-system --timeout=180s'
	$(SSH) ubuntu@control 'kubectl rollout status deployment/calico-apiserver -n calico-apiserver --timeout=180s'
	$(SSH) ubuntu@control 'kubectl get nodes'

cilium: uninstall
	@echo ">>> Installing Cilium (Helm)..."
	$(SSH) ubuntu@control 'helm repo add cilium https://helm.cilium.io/ && helm repo update'
	$(SSH) ubuntu@control 'kubectl -n kube-system delete daemonset kube-proxy 2>/dev/null || true'
	$(SSH) ubuntu@control 'helm install cilium cilium/cilium \
	  --namespace kube-system \
	  --set kubeProxyReplacement=true \
	  --set k8sServiceHost=192.168.100.11 \
	  --set k8sServicePort=6443 \
	  --set hubble.enabled=true \
	  --set hubble.relay.enabled=true \
	  --set hubble.ui.enabled=true \
	  --set ipam.mode=kubernetes \
	  --set tunnel=vxlan'
	@echo ">>> Waiting for Cilium DaemonSet (up to 3 min)..."
	$(SSH) ubuntu@control 'kubectl rollout status daemonset/cilium -n kube-system --timeout=180s'
	$(SSH) ubuntu@control 'kubectl get nodes'

# ─── 状態確認 ─────────────────────────────────────────────────────────────────

status:
	@echo "=== VMs ==="
	@virsh list --all
	@echo ""
	@echo "=== Network ==="
	@virsh net-list --all
	@echo ""
	@echo "=== Disks ($(LIBVIRT_DIR)) ==="
	@sudo ls -lh $(LIBVIRT_DIR) 2>/dev/null || echo "(none)"
	@echo ""
	@echo "=== Kubernetes Nodes ==="
	@$(SSH) ubuntu@control 'kubectl get nodes -o wide' 2>/dev/null || echo "(cluster not ready)"
	@echo ""
	@echo "=== Pods (all namespaces) ==="
	@$(SSH) ubuntu@control 'kubectl get pods -A' 2>/dev/null || echo "(cluster not ready)"

# ─── クリーンアップ ────────────────────────────────────────────────────────────

clean: clean-vms clean-nets clean-seeds

clean-vms:
	-virsh destroy  control 2>/dev/null
	-virsh undefine control --remove-all-storage 2>/dev/null
	-virsh destroy  worker1 2>/dev/null
	-virsh undefine worker1 --remove-all-storage 2>/dev/null
	-virsh destroy  worker2 2>/dev/null
	-virsh undefine worker2 --remove-all-storage 2>/dev/null
	sudo rm -f $(LIBVIRT_DIR)/control.qcow2
	sudo rm -f $(LIBVIRT_DIR)/worker1.qcow2
	sudo rm -f $(LIBVIRT_DIR)/worker2.qcow2
	sudo rm -f $(LIBVIRT_DIR)/control-seed.iso
	sudo rm -f $(LIBVIRT_DIR)/worker1-seed.iso
	sudo rm -f $(LIBVIRT_DIR)/worker2-seed.iso
	@echo ">>> Removing stale SSH host keys (VMs will get new keys on next boot)..."
	@for h in control worker1 worker2 192.168.100.11 192.168.100.12 192.168.100.13; do \
	  ssh-keygen -f "$$HOME/.ssh/known_hosts" -R "$$h" >/dev/null 2>&1 || true; \
	done

clean-nets:
	-virsh net-destroy  k8s 2>/dev/null
	-virsh net-undefine k8s 2>/dev/null

clean-seeds:
	rm -f images/control-seed.iso images/worker1-seed.iso images/worker2-seed.iso

# ─── ヘルプ ───────────────────────────────────────────────────────────────────

help:
	@echo "ターゲット一覧:"
	@echo ""
	@echo "  make all           ネットワーク → seed ISO → VM を一気に作成"
	@echo "  make cluster       VM 作成から kubeadm join まで一気通貫 (CNI 未導入の状態まで)"
	@echo "  make reset         全削除してから make cluster 相当まで再構築 (make clean && make cluster)"
	@echo "  make nets          libvirt 仮想ネットワークのみ作成"
	@echo "  make seeds         cloud-init seed ISO のみ生成 (control/worker1/worker2)"
	@echo "  make vms           VM のみ作成 (nets / seeds / base image が前提)"
	@echo "  make status        VM / ネットワーク / Kubernetes の状態を表示"
	@echo ""
	@echo "  make wait-vms      全 VM が SSH を受け付けるまで待機"
	@echo "  make k8s-prereq    containerd + kubeadm を全ノードにインストール"
	@echo "  make k8s-init      kubeadm init でコントロールプレーンを初期化"
	@echo "  make k8s-join      worker1/2 をクラスタに参加させる"
	@echo ""
	@echo "  make flannel       Flannel をインストール (前の CNI を自動削除)"
	@echo "  make calico        Calico をインストール  (前の CNI を自動削除)"
	@echo "  make cilium        Cilium をインストール  (前の CNI を自動削除)"
	@echo "  make uninstall     CNI をすべてアンインストール"
	@echo ""
	@echo "  make clean         VM・ネットワーク・seed ISO をすべて削除"
	@echo "  make clean-vms     VM とそのディスクのみ削除"
	@echo "  make clean-nets    仮想ネットワークのみ削除"
	@echo "  make clean-seeds   ローカル seed ISO のみ削除"
	@echo ""
	@echo "典型的なフロー:"
	@echo "  make cluster       # VM 作成〜kubeadm join まで1コマンド"
	@echo "  make flannel       # Flannel を体験"
	@echo "  make calico        # Calico に切り替え"
	@echo "  make cilium        # Cilium に切り替え"

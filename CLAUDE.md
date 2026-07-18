# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

Not an application codebase — it's a hands-on Kubernetes **CNI comparison lab**. A `Makefile` drives KVM/libvirt to provision 3 VMs on a single Mini PC host (Ubuntu 24.04), bootstraps a `kubeadm` cluster across them, and lets you swap between Flannel / Calico / Cilium to observe how each implements Pod networking, Services, and NetworkPolicy at the packet level (routing tables, `tcpdump`, eBPF maps, etc.). There is no application code to build/lint/test in the usual sense — "correctness" means the `make` targets converge to a working cluster and the documented `tcpdump`/`ip route`/`bpftool` commands in each chapter produce the described output.

The numbered `.md` files are a sequential tutorial, not reference docs to skim in isolation — content in later chapters assumes state left by earlier ones (see "Doc structure" below).

## Commands

All operations go through the `Makefile` and SSH to the VMs (`ubuntu@control`, `ubuntu@worker1`, `ubuntu@worker2` — resolved via `/etc/hosts`, see `00-setup.md`). Run `make help` for the full annotated list.

```bash
make cluster        # VM provisioning -> kubeadm cluster, CNI not yet installed (chains: nets -> seeds -> vms -> wait-vms -> k8s-prereq -> k8s-init -> k8s-join)
make flannel        # install Flannel (runs `uninstall` first, so any CNI can be installed from any prior state)
make calico         # install Calico
make cilium         # install Cilium
make uninstall      # tear down whichever CNI is installed and restore the kube-proxy addon
make status         # VM / libvirt network / node / pod status in one shot
make reset          # make clean && make cluster (full rebuild)
make clean          # delete VMs, libvirt network, seed ISOs (destructive)
```

Finer-grained targets exist if you only need part of the chain: `nets`, `seeds`, `vms`, `wait-vms`, `k8s-prereq`, `k8s-init`, `k8s-join`, `clean-vms`, `clean-nets`, `clean-seeds`.

`flannel`/`calico`/`cilium` are deliberately **order-independent** — each depends only on `uninstall`, not on each other. When changing `uninstall`, preserve this: it must fully reverse whatever the previously-installed CNI did (e.g. Cilium's `kubeProxyReplacement` deletes the `kube-proxy` DaemonSet, so `uninstall` restores it via `kubeadm init phase addon kube-proxy`, and deletes CNI-specific interfaces like `flannel.1`/`cni0`/`tunl0`/`cilium_vxlan`/`cilium_host`/`cilium_net` on every node).

There's no CI here — verifying a change means actually running the relevant `make` target against real VMs (or at minimum reasoning through the SSH/kubectl command sequence), since this is infrastructure automation, not code with a test suite.

## Architecture

### Topology (fixed, referenced throughout the docs)

- Host: Mini PC, KVM/libvirt, `virbr10` bridge, network `192.168.100.0/24` (`net/k8s-mgmt-net.xml`, DHCP host reservations tie MAC -> hostname -> IP)
- `control` = `192.168.100.11` (control-plane), `worker1` = `.12`, `worker2` = `.13`
- Pod CIDR `10.244.0.0/16`, Service CIDR `10.96.0.0/12`, kubeadm/kubelet/kubectl pinned to v1.31 (`pkgs.k8s.io/core:/stable:/v1.31`), base image Ubuntu 24.04 (noble)

### Provisioning flow

1. `cloud-init/user-data.tmpl` + `network-config.tmpl` are per-node templates; `cloud-init/make-seed.sh <hostname>` renders them and builds a seed ISO per node (`make seeds`).
2. `make vms` downloads the Ubuntu cloud image once, then `qemu-img`/`virt-install`s each of the 3 VMs against it + its seed ISO.
3. `make wait-vms` blocks on SSH availability *and* `cloud-init status --wait` on every node — this second wait exists because cloud-init's own `packages:` apt run can still hold the apt lock after sshd is already accepting connections, which previously raced with `k8s-prereq`'s `apt update`.
4. `scripts/k8s-prereq.sh` (run via SSH, not copied to the VM) installs containerd + kubeadm/kubelet/kubectl on all 3 nodes.
5. `k8s-init` runs `kubeadm init` on `control` and saves kubeconfig to `~/.kube/k8s-lab.config` on the host; `k8s-join` joins the two workers.

### CNI switching

`uninstall` removes all traces of whichever CNI is active (manifests/Helm release/CRDs/node-level interfaces/CNI conf files) and is always run before installing a new one — this is what makes `flannel`/`calico`/`cilium` safe to invoke in any order or from a fresh cluster. Each CNI chapter's own "uninstall" section in the `.md` files documents the same steps manually for teaching purposes, but `make uninstall` is the actual mechanism.

`manifests/nginx-ds.yaml` (an nginx DaemonSet + ClusterIP Service + a `debug` busybox pod) is the shared test workload reused identically across all three CNI chapters, so behavior is comparable apples-to-apples.

### Doc structure and numbering convention

- `00-setup.md` — host prep (manual, one-time) + `make cluster` as the primary path; the old manual VM/kubeadm walkthrough is kept as a reference appendix (section 0.3), not the main flow.
- `01-flannel.md`, `02-calico.md`, `03-cilium.md` — one chapter per CNI. Each follows the same internal shape: install -> same-node Pod-to-Pod (no encapsulation) -> cross-node Pod-to-Pod (CNI-specific encapsulation/routing) -> Service path -> Pod-to-internet (SNAT) -> NetworkPolicy where supported -> summary table -> uninstall.
- `04-comparison.md` — cross-CNI summary, including an intra-node vs inter-node comparison table.
- **Heading numbers match the chapter/file number** (`02-calico.md` uses `## 2.1`, `## 2.2`, ...), and chapters cross-link each other with GitHub-style anchors derived from those headings (e.g. `01-flannel.md#110-flannel-...`). If you reorder, rename, or insert a section into any of these files, you must renumber every subsequent heading in that file *and* fix every cross-chapter anchor/prose reference that points at it (self-references like "次の 2.7 で確認する" exist inside the same file too, not just cross-file links) — this repo has no automated link checker, so these were verified by hand/grep.

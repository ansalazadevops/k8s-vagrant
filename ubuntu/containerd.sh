#!/usr/bin/env bash
# Prepare a node for kubeadm: kernel settings, containerd 2.x, kubelet/kubeadm/kubectl.
# Idempotent: safe to re-run with `vagrant provision`.
set -euo pipefail

: "${NODE_IP:?NODE_IP must be set}"
: "${NODE_IPV6:?NODE_IPV6 must be set}"
KUBE_VERSION="${KUBE_VERSION:-}"
export DEBIAN_FRONTEND=noninteractive

# 1. Disable swap (now and after reboot)
swapoff -a
sed -i -E '/[[:space:]]swap[[:space:]]/ s/^#*/#/' /etc/fstab

# 1b. Persistent systemd journal in /var/log/journal, so the log collector
#     (Grafana Alloy) can read kubelet/containerd/kernel logs from the host.
if [ ! -d /var/log/journal ]; then
    mkdir -p /var/log/journal
    systemd-tmpfiles --create --prefix /var/log/journal
    systemctl restart systemd-journald
fi

# 2. Kernel modules + sysctl (overwrite, don't append, so re-runs don't duplicate)
cat > /etc/modules-load.d/k8s.conf <<CFG
overlay
br_netfilter
CFG
modprobe overlay
modprobe br_netfilter

cat > /etc/sysctl.d/k8s.conf <<CFG
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv6.conf.all.forwarding        = 1
net.ipv6.conf.all.disable_ipv6      = 0
net.ipv6.conf.default.disable_ipv6  = 0
CFG
sysctl --system > /dev/null

# 3. Base packages. Remove Ubuntu's containerd/runc if present: Kubernetes
#    >= 1.36 requires containerd 2.x, which we take from Docker's repo.
apt-get update -q
apt-get install -y -q ca-certificates curl gpg
apt-get remove -y -q containerd runc docker.io 2>/dev/null || true

install -d -m 755 /etc/apt/keyrings

# 4. containerd 2.x (containerd.io from download.docker.com; ships runc too)
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor --yes -o /etc/apt/keyrings/docker.gpg
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    > /etc/apt/sources.list.d/docker.list

# 5. Kubernetes apt repo + tools
if [ -z "$KUBE_VERSION" ]; then
    KUBE_VERSION="$(curl -fsSL https://dl.k8s.io/release/stable.txt | cut -d. -f1,2)"
fi
echo "[k8s-node] Kubernetes repo: ${KUBE_VERSION}"

curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBE_VERSION}/deb/Release.key" \
    | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBE_VERSION}/deb/ /" \
    > /etc/apt/sources.list.d/kubernetes.list

apt-get update -q
apt-get install -y -q containerd.io kubelet kubeadm kubectl
apt-mark hold containerd.io kubelet kubeadm kubectl

CTR_MAJOR="$(containerd --version | awk '{print $3}' | sed 's/^v//' | cut -d. -f1)"
if [ "$CTR_MAJOR" -lt 2 ]; then
    echo "[k8s-node] containerd $(containerd --version) is < 2.0; Kubernetes >= 1.36 needs 2.x" >&2
    exit 1
fi

# 6. containerd config: systemd cgroups + the pause image kubeadm expects.
#    (containerd.io ships a config with the CRI plugin disabled, so regenerate it.)
PAUSE_IMAGE="$(kubeadm config images list --kubernetes-version "$(kubeadm version -o short)" 2>/dev/null | grep pause || true)"
PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10.1}"

mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i -E 's/^([[:space:]]*)SystemdCgroup = false/\1SystemdCgroup = true/' /etc/containerd/config.toml
if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
    # containerd 2.x: add the key under the runc options table if it wasn't printed
    sed -i -E "/^[[:space:]]*\[plugins\.'io\.containerd\.cri\.v1\.runtime'\.containerd\.runtimes\.runc\.options\]/a\            SystemdCgroup = true" \
        /etc/containerd/config.toml
fi
sed -i -E "s#^([[:space:]]*sandbox[[:space:]]*=).*#\1 '${PAUSE_IMAGE}'#" /etc/containerd/config.toml  # containerd 2.x
grep -q 'SystemdCgroup = true' /etc/containerd/config.toml \
    || { echo "[k8s-node] could not enable SystemdCgroup in containerd config" >&2; exit 1; }

systemctl enable containerd
systemctl restart containerd

cat > /etc/crictl.yaml <<CFG
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
CFG

# 7. Pin kubelet to the host-only dual-stack IPs (NOT the NAT address 10.0.2.15).
#    IPv4 first: it must match the primary family of the pod/service CIDRs.
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP},${NODE_IPV6}" > /etc/default/kubelet
systemctl daemon-reload
systemctl enable kubelet
systemctl restart kubelet || true   # crash-loops until kubeadm init/join; that's expected

echo "[k8s-node] ready: containerd $(containerd --version | awk '{print $3}'), kubeadm $(kubeadm version -o short), node-ip ${NODE_IP},${NODE_IPV6}"

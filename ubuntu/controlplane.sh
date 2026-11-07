#!/usr/bin/env bash
# Initialise a dual-stack control plane, install Calico, publish the join command.
# Idempotent: re-running skips what is already done and refreshes the join command.
set -euo pipefail

: "${NODE_IP:?NODE_IP must be set}"
: "${NODE_IPV6:?NODE_IPV6 must be set}"
NODE_NETWORK="${NODE_NETWORK:-192.168.56.0/24}"
NODE_NETWORK_IPV6="${NODE_NETWORK_IPV6:-fd00:192:168:56::/64}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16,fd00:10:244::/56}"
SERVICE_CIDR="${SERVICE_CIDR:-10.96.0.0/16,fd00:10:96::/112}"
CALICO_VERSION="${CALICO_VERSION:-v3.32.2}"
METRICS_SERVER_VERSION="${METRICS_SERVER_VERSION:-}"   # e.g. v0.9.0; empty = latest release

POD_CIDR_V4="${POD_CIDR%%,*}"
POD_CIDR_V6="${POD_CIDR##*,}"

export KUBECONFIG=/etc/kubernetes/admin.conf
JOIN_FILE=/vagrant/join.sh
KUBEADM_CFG=/root/kubeadm-config.yaml

# Remove any join command left over from a previous (destroyed) cluster
rm -f "$JOIN_FILE"

# 1. kubeadm init. Dual-stack needs a config file: --apiserver-advertise-address
#    takes only ONE address, and node-ip must list both families.
#    kubeadm.k8s.io/v1beta4 requires Kubernetes >= 1.31.
if [ ! -f /etc/kubernetes/admin.conf ]; then
    cat > "$KUBEADM_CFG" <<YAML
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${NODE_IP}"
  bindPort: 6443
nodeRegistration:
  name: "$(hostname)"
  criSocket: unix:///run/containerd/containerd.sock
  kubeletExtraArgs:
    - name: node-ip
      value: "${NODE_IP},${NODE_IPV6}"
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
controlPlaneEndpoint: "${NODE_IP}:6443"
networking:
  podSubnet: "${POD_CIDR}"
  serviceSubnet: "${SERVICE_CIDR}"
apiServer:
  certSANs:
    - "${NODE_IP}"
    - "${NODE_IPV6}"
    - "$(hostname)"
# Prometheus (kube-prometheus-stack) scrapes these components from inside the
# pod network. kubeadm binds their metrics endpoints to 127.0.0.1 by default,
# which makes those targets permanently DOWN. Metrics on controller-manager and
# scheduler still require an authorised token; etcd/kube-proxy metrics are
# read-only and only reachable on the private host-only network.
controllerManager:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
scheduler:
  extraArgs:
    - name: bind-address
      value: "0.0.0.0"
etcd:
  local:
    extraArgs:
      - name: listen-metrics-urls
        value: "http://0.0.0.0:2381"
---
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
metricsBindAddress: "0.0.0.0:10249"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
# Kubelets request a CA-signed serving cert (approved by approve-csr.sh) so
# metrics-server can verify them without --kubelet-insecure-tls. kubeadm
# stores this config in the kubelet-config ConfigMap, so workers inherit it.
serverTLSBootstrap: true
YAML
    kubeadm init --config "$KUBEADM_CFG" | tee /root/kubeadm-init.out
else
    echo "[controlplane] already initialised, skipping kubeadm init"
fi

# 2. kubeconfig for the vagrant user, plus a copy for the host
install -d -o vagrant -g vagrant -m 700 /home/vagrant/.kube
install -o vagrant -g vagrant -m 600 /etc/kubernetes/admin.conf /home/vagrant/.kube/config
install -m 600 /etc/kubernetes/admin.conf /vagrant/admin.conf 2>/dev/null || true

# 3. Wait for the API server
echo "[controlplane] waiting for API server..."
for _ in $(seq 1 60); do
    kubectl get --raw=/readyz > /dev/null 2>&1 && break
    sleep 5
done
kubectl get --raw=/readyz > /dev/null

# 4. Calico via the Tigera operator (server-side apply: the CRD bundle is too
#    large for client-side apply's last-applied annotation).
CALICO_BASE="https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests"
kubectl apply --server-side --force-conflicts -f "${CALICO_BASE}/v1_crd_projectcalico_org.yaml"
kubectl apply --server-side --force-conflicts -f "${CALICO_BASE}/tigera-operator.yaml"
kubectl wait --for condition=established --timeout=120s \
    crd/installations.operator.tigera.io crd/apiservers.operator.tigera.io

# Dual-stack Installation. Pool CIDRs MUST match the kubeadm podSubnet.
kubectl apply --server-side --force-conflicts -f - <<YAML
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
      - name: default-ipv4-ippool
        blockSize: 26
        cidr: "${POD_CIDR_V4}"
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
      - name: default-ipv6-ippool
        blockSize: 122
        cidr: "${POD_CIDR_V6}"
        encapsulation: VXLANCrossSubnet
        natOutgoing: Enabled
        nodeSelector: all()
    # Pick the host-only NIC, never the NAT NIC (10.0.2.15 on every VM)
    nodeAddressAutodetectionV4:
      cidrs:
        - "${NODE_NETWORK}"
    nodeAddressAutodetectionV6:
      cidrs:
        - "${NODE_NETWORK_IPV6}"
---
apiVersion: operator.tigera.io/v1
kind: APIServer
metadata:
  name: default
spec: {}
YAML

# 5. Approve the control plane's kubelet serving certificate
bash /vagrant/ubuntu/approve-csr.sh "$(hostname)" || true

# 6. Metrics API (metrics-server -> metrics.k8s.io, used by kubectl top and HPA).
#    The control plane is tainted, so the pod is only scheduled once the first
#    worker joins; the last worker waits for it to become Available.
if [ -n "$METRICS_SERVER_VERSION" ]; then
    METRICS_URL="https://github.com/kubernetes-sigs/metrics-server/releases/download/${METRICS_SERVER_VERSION}/components.yaml"
else
    METRICS_URL="https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml"
fi
echo "[controlplane] installing metrics-server from ${METRICS_URL}"
kubectl apply --server-side --force-conflicts -f "$METRICS_URL"

# 7. Publish a fresh join command (tokens expire after 24h; re-run this
#    provisioner to refresh: vagrant provision klabcp --provision-with kubeadm-init)
kubeadm token create --ttl 24h --print-join-command > "${JOIN_FILE}.tmp"
mv "${JOIN_FILE}.tmp" "$JOIN_FILE"
echo "[controlplane] join command written to $JOIN_FILE:"
cat "$JOIN_FILE"

kubectl get nodes -o wide

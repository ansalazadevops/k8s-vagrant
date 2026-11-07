#!/usr/bin/env bash
# Join this node to the cluster, approve its kubelet serving certificate and,
# on the last worker, wait for the Metrics API. Idempotent.
# The dual-stack node IPs come from /etc/default/kubelet (written by containerd.sh).
set -euo pipefail

: "${CONTROLPLANE_IP:?CONTROLPLANE_IP must be set}"
LAST_WORKER="${LAST_WORKER:-false}"
JOIN_FILE=/vagrant/join.sh
NODE="$(hostname)"

# 1. Join (kubelet.conf only exists after a successful join. Checking
#    "systemctl is-active kubelet" is unreliable: it can be briefly active
#    while crash-looping.)
if [ -f /etc/kubernetes/kubelet.conf ]; then
    echo "[worker] ${NODE} already joined, skipping kubeadm join"
else
    echo "[worker] waiting for join command..."
    for _ in $(seq 1 60); do
        [ -s "$JOIN_FILE" ] && break
        sleep 5
    done
    [ -s "$JOIN_FILE" ] || { echo "[worker] $JOIN_FILE not found - provision klabcp first"; exit 1; }

    # Guard against a stale file or a control plane advertising the wrong
    # address (e.g. the NAT address 10.0.2.15)
    if ! grep -q "${CONTROLPLANE_IP}:6443" "$JOIN_FILE"; then
        echo "[worker] join command does not point at ${CONTROLPLANE_IP}:6443:"
        cat "$JOIN_FILE"
        exit 1
    fi

    echo "[worker] waiting for API server at ${CONTROLPLANE_IP}:6443..."
    for _ in $(seq 1 60); do
        curl -ksf "https://${CONTROLPLANE_IP}:6443/livez" > /dev/null && break
        sleep 5
    done
    curl -ksf "https://${CONTROLPLANE_IP}:6443/livez" > /dev/null

    bash "$JOIN_FILE"
    echo "[worker] ${NODE} joined the cluster"
fi

# 2. Approve this node's kubelet serving cert, using the admin kubeconfig the
#    control plane published to the shared /vagrant folder.
export KUBECONFIG=/vagrant/admin.conf
bash /vagrant/ubuntu/approve-csr.sh "$NODE" || true

# 3. Last worker: wait for the Metrics API to come up and show it.
if [ "$LAST_WORKER" = "true" ]; then
    echo "[worker] waiting for metrics-server..."
    if kubectl -n kube-system rollout status deployment/metrics-server --timeout=300s \
       && kubectl wait --for=condition=Available --timeout=180s apiservice/v1beta1.metrics.k8s.io; then
        # The first scrape needs up to ~1 min after the API is available
        for _ in $(seq 1 24); do
            kubectl top nodes 2>/dev/null && break
            sleep 5
        done
    else
        echo "[worker] WARNING: metrics-server not ready yet; check with:" >&2
        echo "  kubectl -n kube-system logs deploy/metrics-server; kubectl get csr" >&2
    fi
fi

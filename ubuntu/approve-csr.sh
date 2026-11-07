#!/usr/bin/env bash
# Approve the kubelet *serving* certificate request of one node.
#
# With serverTLSBootstrap: true (set in the kubeadm KubeletConfiguration) each
# kubelet asks the cluster CA for its HTTPS serving certificate instead of
# using a self-signed one. Kubernetes never auto-approves these, so we approve
# them here. A CA-signed kubelet cert is what lets metrics-server verify the
# kubelet without --kubelet-insecure-tls (it also fixes kubectl logs/exec TLS).
#
# Usage: approve-csr.sh <node-name>    (needs KUBECONFIG with admin rights)
set -euo pipefail

NODE="${1:?usage: approve-csr.sh <node-name>}"
USER_NAME="system:node:${NODE}"

list_csrs() {
    # name  username  conditions  (conditions is empty while Pending)
    kubectl get csr -o jsonpath='{range .items[?(@.spec.signerName=="kubernetes.io/kubelet-serving")]}{.metadata.name}{"\t"}{.spec.username}{"\t"}{.status.conditions[*].type}{"\n"}{end}'
}

echo "[csr] waiting for the kubelet-serving CSR of ${NODE}..."
for _ in $(seq 1 60); do
    CSRS="$(list_csrs 2>/dev/null || true)"

    # Only approve requests made by this node's own kubelet identity
    PENDING="$(awk -F'\t' -v u="$USER_NAME" '$2 == u && $3 == "" { print $1 }' <<< "$CSRS")"
    if [ -n "$PENDING" ]; then
        # shellcheck disable=SC2086
        kubectl certificate approve $PENDING
    fi

    if awk -F'\t' -v u="$USER_NAME" '$2 == u && $3 ~ /Approved/ { found = 1 } END { exit !found }' <<< "$CSRS"; then
        echo "[csr] ${NODE}: kubelet serving certificate approved"
        exit 0
    fi
    sleep 5
done

echo "[csr] WARNING: no kubelet-serving CSR approved for ${NODE} after 5 min." >&2
echo "[csr] Approve it later with: kubectl get csr; kubectl certificate approve <name>" >&2
exit 1

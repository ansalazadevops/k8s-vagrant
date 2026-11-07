#!/usr/bin/env bash
# Install MetalLB with Helm (L2 mode) and give it a dual-stack address pool on
# the host-only network. Idempotent: safe to re-run with `vagrant provision`.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/vagrant/admin.conf}"
METALLB_VERSION="${METALLB_VERSION:-}"                     # chart version; empty = latest
METALLB_POOL_V4="${METALLB_POOL_V4:-192.168.56.200-192.168.56.220}"
METALLB_POOL_V6="${METALLB_POOL_V6:-fd00:192:168:56::200-fd00:192:168:56::220}"
NS=metallb-system

[ -f "$KUBECONFIG" ] || { echo "[metallb] kubeconfig $KUBECONFIG not found" >&2; exit 1; }

# 1. Install / upgrade the chart. The speaker needs privileged pods, so label
#    the namespace for Pod Security before the pods are created.
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" --overwrite \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged

helm repo add --force-update metallb https://metallb.github.io/metallb
helm repo update
helm upgrade --install metallb metallb/metallb \
    --namespace "$NS" \
    ${METALLB_VERSION:+--version "$METALLB_VERSION"} \
    --wait --timeout 10m

# 2. Address pool + L2 announcement. One pool holding BOTH families is what
#    lets MetalLB give a dual-stack Service an IPv4 and an IPv6 address.
#    Retry: the validating webhook can take a moment to accept requests even
#    after the controller reports Ready.
echo "[metallb] configuring pool ${METALLB_POOL_V4} + ${METALLB_POOL_V6}"
for i in $(seq 1 30); do
    if kubectl apply -f - <<YAML
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: ${NS}
spec:
  addresses:
    - ${METALLB_POOL_V4}
    - ${METALLB_POOL_V6}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-l2
  namespace: ${NS}
spec:
  ipAddressPools:
    - default-pool
YAML
    then
        break
    fi
    [ "$i" -eq 30 ] && { echo "[metallb] webhook never accepted the pool" >&2; exit 1; }
    echo "[metallb] webhook not ready yet, retrying ($i/30)..."
    sleep 10
done

kubectl -n "$NS" get pods -o wide
kubectl -n "$NS" get ipaddresspools.metallb.io,l2advertisements.metallb.io
echo "[metallb] ready"

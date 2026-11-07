#!/usr/bin/env bash
# Install Traefik with Helm as the default ingress controller, exposed through
# a dual-stack LoadBalancer Service on fixed MetalLB IPs. Idempotent.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/vagrant/admin.conf}"
TRAEFIK_VERSION="${TRAEFIK_VERSION:-}"                       # chart version; empty = latest
TRAEFIK_LB_IPS="${TRAEFIK_LB_IPS:-192.168.56.200,fd00:192:168:56::200}"
NS=traefik
VALUES=/root/traefik-values.yaml

[ -f "$KUBECONFIG" ] || { echo "[traefik] kubeconfig $KUBECONFIG not found" >&2; exit 1; }
kubectl get crd ipaddresspools.metallb.io > /dev/null 2>&1 \
    || { echo "[traefik] MetalLB is not installed; run metallb.sh first" >&2; exit 1; }

# Values: a dual-stack LoadBalancer with one fixed IP per family. MetalLB
# needs the annotation for dual-stack (spec.loadBalancerIP can't carry two IPs).
cat > "$VALUES" <<YAML
ingressClass:
  enabled: true
  isDefaultClass: true
service:
  annotations:
    metallb.io/loadBalancerIPs: "${TRAEFIK_LB_IPS}"
  spec:
    type: LoadBalancer
    ipFamilyPolicy: RequireDualStack
    ipFamilies:
      - IPv4
      - IPv6
YAML

helm repo add --force-update traefik https://traefik.github.io/charts
helm repo update
helm upgrade --install traefik traefik/traefik \
    --namespace "$NS" --create-namespace \
    ${TRAEFIK_VERSION:+--version "$TRAEFIK_VERSION"} \
    -f "$VALUES" \
    --wait --timeout 10m

# Wait until MetalLB has assigned the external IPs
echo "[traefik] waiting for LoadBalancer IPs..."
for _ in $(seq 1 30); do
    IPS="$(kubectl -n "$NS" get svc traefik -o jsonpath='{.status.loadBalancer.ingress[*].ip}')"
    [ -n "$IPS" ] && break
    sleep 5
done
kubectl -n "$NS" get svc traefik -o wide

if [ -z "${IPS:-}" ]; then
    echo "[traefik] WARNING: no external IP yet; check: kubectl -n metallb-system logs deploy/metallb-controller" >&2
    exit 0
fi
echo "[traefik] external IPs: ${IPS}"

# Smoke test: with no Ingress defined yet, Traefik answers 404
V4="${TRAEFIK_LB_IPS%%,*}"
CODE="$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://${V4}/" || true)"
echo "[traefik] http://${V4}/ -> HTTP ${CODE} (404 is expected until you create an Ingress)"

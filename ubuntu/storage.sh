#!/usr/bin/env bash
# Install Rancher's local-path-provisioner and make it the default StorageClass,
# so PersistentVolumeClaims (Prometheus, Loki, ...) get a volume on the node's
# disk (/opt/local-path-provisioner). Fine for a lab: data lives on one node
# and is lost if that VM is destroyed. Idempotent.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/vagrant/admin.conf}"
LOCAL_PATH_VERSION="${LOCAL_PATH_VERSION:-v0.0.35}"

[ -f "$KUBECONFIG" ] || { echo "[storage] kubeconfig $KUBECONFIG not found" >&2; exit 1; }

kubectl apply -f "https://raw.githubusercontent.com/rancher/local-path-provisioner/${LOCAL_PATH_VERSION}/deploy/local-path-storage.yaml"
kubectl -n local-path-storage rollout status deployment/local-path-provisioner --timeout=300s

# Make local-path the only default StorageClass
for sc in $(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{" "}{end}'); do
    [ "$sc" = "local-path" ] || kubectl patch storageclass "$sc" \
        -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}'
done
kubectl patch storageclass local-path \
    -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

kubectl get storageclass
echo "[storage] local-path is the default StorageClass"

#!/usr/bin/env bash
# Observability stack, installed with Helm into the "monitoring" namespace:
#
#   metrics  kube-prometheus-stack: Prometheus, Alertmanager, Grafana,
#            node-exporter (node metrics) and kube-state-metrics (state of
#            every Kubernetes object: pods, deployments, nodes, PVCs, ...)
#   logs     Loki (single binary, filesystem storage on a local-path PVC)
#   shipping Grafana Alloy
#              - DaemonSet "alloy": pod/container logs (/var/log/pods) and the
#                node systemd journal (kubelet, containerd, kernel, sshd...)
#              - Deployment "alloy-events": Kubernetes events (one replica,
#                so each event is stored once)
#
# Grafana and Prometheus are published through Traefik (Ingress).
# Idempotent: re-running upgrades the releases in place.
set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-/vagrant/admin.conf}"
NS=monitoring
OBS_DOMAIN="${OBS_DOMAIN:-192.168.56.200.nip.io}"     # grafana.<domain>, prometheus.<domain>
CLUSTER_NAME="${CLUSTER_NAME:-vagrant-k8s}"
PROM_RETENTION="${PROM_RETENTION:-3d}"
PROM_STORAGE="${PROM_STORAGE:-5Gi}"
LOKI_RETENTION="${LOKI_RETENTION:-72h}"
LOKI_STORAGE="${LOKI_STORAGE:-5Gi}"
KPS_VERSION="${KPS_VERSION:-}"       # kube-prometheus-stack chart version; empty = latest
LOKI_VERSION="${LOKI_VERSION:-}"     # loki chart version; empty = latest
ALLOY_VERSION="${ALLOY_VERSION:-}"   # alloy chart version; empty = latest
PASSWORD_FILE=/vagrant/.grafana-admin-password
DASHBOARD_JSON=/vagrant/ubuntu/dashboards/k8s-logs.json
WORK=/root/observability
LOKI_URL="http://loki.${NS}.svc.cluster.local:3100"

[ -f "$KUBECONFIG" ] || { echo "[obs] kubeconfig $KUBECONFIG not found" >&2; exit 1; }
kubectl get storageclass local-path > /dev/null 2>&1 \
    || { echo "[obs] no local-path StorageClass; run storage.sh first" >&2; exit 1; }
mkdir -p "$WORK"

# --- 0. Namespace (node-exporter and Alloy need hostPath / hostNetwork) -------
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
kubectl label namespace "$NS" --overwrite \
    pod-security.kubernetes.io/enforce=privileged \
    pod-security.kubernetes.io/audit=privileged \
    pod-security.kubernetes.io/warn=privileged

# Grafana admin password: generated once, kept in the shared folder so it
# survives re-provisioning (and you can read it from the host).
if [ ! -s "$PASSWORD_FILE" ]; then
    openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20 > "$PASSWORD_FILE"
fi
GRAFANA_PASSWORD="$(cat "$PASSWORD_FILE")"

helm repo add --force-update prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add --force-update grafana https://grafana.github.io/helm-charts
helm repo update

# --- 1. Loki ----------------------------------------------------------------
cat > "$WORK/loki-values.yaml" <<YAML
deploymentMode: SingleBinary
loki:
  auth_enabled: false            # single tenant lab setup
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  limits_config:
    retention_period: ${LOKI_RETENTION}
    allow_structured_metadata: true
    volume_enabled: true
  compactor:
    retention_enabled: true
    delete_request_store: filesystem
singleBinary:
  replicas: 1
  persistence:
    enabled: true
    storageClass: local-path
    size: ${LOKI_STORAGE}
  resources:
    requests: { cpu: 100m, memory: 256Mi }
    limits:   { memory: 1Gi }
# Single binary only: switch off the scalable / distributed components
backend: { replicas: 0 }
read:    { replicas: 0 }
write:   { replicas: 0 }
chunksCache:  { enabled: false }
resultsCache: { enabled: false }
gateway:      { enabled: false }
lokiCanary:   { enabled: false }
test:         { enabled: false }
YAML

echo "[obs] installing Loki"
helm upgrade --install loki grafana/loki -n "$NS" \
    ${LOKI_VERSION:+--version "$LOKI_VERSION"} \
    -f "$WORK/loki-values.yaml" --wait --timeout 15m

# --- 2. kube-prometheus-stack (Prometheus + Grafana + exporters) -------------
# Control-plane components are only scrapeable if kubeadm bound their metrics
# endpoints beyond 127.0.0.1 (done in controlplane.sh for new clusters). On an
# older cluster, skip those targets instead of showing them as DOWN forever.
cm_args="$(kubectl -n kube-system get pods -l component=kube-controller-manager -o jsonpath='{.items[0].spec.containers[0].command}' 2>/dev/null || true)"
if grep -q -- '--bind-address=0.0.0.0' <<< "$cm_args"; then CP_METRICS=true; else CP_METRICS=false; fi
if kubectl -n kube-system get configmap kube-proxy -o jsonpath='{.data.config\.conf}' 2>/dev/null | grep -q 'metricsBindAddress: 0.0.0.0'; then
    PROXY_METRICS=true; else PROXY_METRICS=false; fi
echo "[obs] control-plane metrics: ${CP_METRICS}, kube-proxy metrics: ${PROXY_METRICS}"

cat > "$WORK/kps-values.yaml" <<YAML
fullnameOverride: kps
kubeControllerManager: { enabled: ${CP_METRICS} }
kubeScheduler:         { enabled: ${CP_METRICS} }
kubeEtcd:
  enabled: ${CP_METRICS}
  service: { enabled: true, port: 2381, targetPort: 2381 }
kubeProxy: { enabled: ${PROXY_METRICS} }

prometheus:
  ingress:
    enabled: true
    ingressClassName: traefik
    hosts: [ "prometheus.${OBS_DOMAIN}" ]
    paths: [ "/" ]
    pathType: Prefix
  prometheusSpec:
    retention: ${PROM_RETENTION}
    # Pick up ServiceMonitors / PodMonitors / rules from ANY release or namespace
    serviceMonitorSelectorNilUsesHelmValues: false
    podMonitorSelectorNilUsesHelmValues: false
    ruleSelectorNilUsesHelmValues: false
    probeSelectorNilUsesHelmValues: false
    externalLabels: { cluster: "${CLUSTER_NAME}" }
    resources:
      requests: { cpu: 200m, memory: 512Mi }
      limits:   { memory: 1536Mi }
    storageSpec:
      volumeClaimTemplate:
        spec:
          storageClassName: local-path
          accessModes: [ "ReadWriteOnce" ]
          resources: { requests: { storage: ${PROM_STORAGE} } }

alertmanager:
  alertmanagerSpec:
    resources:
      requests: { cpu: 20m, memory: 64Mi }
      limits:   { memory: 128Mi }

grafana:
  adminPassword: "${GRAFANA_PASSWORD}"
  defaultDashboardsTimezone: browser
  ingress:
    enabled: true
    ingressClassName: traefik
    hosts: [ "grafana.${OBS_DOMAIN}" ]
    path: /
  resources:
    requests: { cpu: 50m, memory: 128Mi }
    limits:   { memory: 384Mi }
  # Loki next to the Prometheus datasource the chart creates
  additionalDataSources:
    - name: Loki
      uid: loki
      type: loki
      access: proxy
      url: ${LOKI_URL}
      jsonData: { maxLines: 1000 }
  # Load dashboards from ConfigMaps labelled grafana_dashboard=1 (any namespace)
  sidecar:
    dashboards:
      enabled: true
      label: grafana_dashboard
      labelValue: "1"
      searchNamespace: ALL

prometheus-node-exporter:
  resources:
    requests: { cpu: 20m, memory: 32Mi }
    limits:   { memory: 64Mi }
kube-state-metrics:
  resources:
    requests: { cpu: 20m, memory: 64Mi }
    limits:   { memory: 128Mi }
YAML

echo "[obs] installing kube-prometheus-stack"
helm upgrade --install kps prometheus-community/kube-prometheus-stack -n "$NS" \
    ${KPS_VERSION:+--version "$KPS_VERSION"} \
    -f "$WORK/kps-values.yaml" --wait --timeout 20m

# --- 3. Grafana Alloy: pod logs + node journal (DaemonSet on every node) -----
cat > "$WORK/alloy-values.yaml" <<YAML
alloy:
  configMap:
    create: true
    content: |
      logging {
        level  = "info"
        format = "logfmt"
      }

      loki.write "default" {
        endpoint {
          url = "${LOKI_URL}/loki/api/v1/push"
        }
        external_labels = { cluster = "${CLUSTER_NAME}" }
      }

      // ---- Pod / container logs: the files kubelet writes on THIS node ----
      discovery.kubernetes "pods" {
        role = "pod"
        selectors {
          role  = "pod"
          field = "spec.nodeName=" + coalesce(sys.env("NODE_NAME"), constants.hostname)
        }
      }

      discovery.relabel "pods" {
        targets = discovery.kubernetes.pods.targets

        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_node_name"]
          target_label  = "node"
        }
        // app = first non-empty of app.kubernetes.io/name, app, k8s-app, container name
        rule {
          source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name", "__meta_kubernetes_pod_label_app", "__meta_kubernetes_pod_label_k8s_app", "__meta_kubernetes_pod_container_name"]
          regex         = "^;*([^;]+)(;.*)?$"
          target_label  = "app"
        }
        rule {
          source_labels = ["namespace", "app"]
          separator     = "/"
          target_label  = "job"
        }
        // /var/log/pods/<namespace>_<pod>_<uid>/<container>/<n>.log
        rule {
          source_labels = ["__meta_kubernetes_pod_uid", "__meta_kubernetes_pod_container_name"]
          separator     = "/"
          target_label  = "__path__"
          replacement   = "/var/log/pods/*\$1/*.log"
        }
      }

      local.file_match "pods" {
        path_targets = discovery.relabel.pods.output
      }

      loki.source.file "pods" {
        targets    = local.file_match.pods.targets
        forward_to = [loki.process.pods.receiver]
      }

      loki.process "pods" {
        // containerd writes CRI format: "<time> <stream> <P|F> <message>"
        stage.cri {}
        forward_to = [loki.write.default.receiver]
      }

      // ---- Node logs: systemd journal (kubelet, containerd, kernel, ssh...) ----
      loki.relabel "journal" {
        forward_to = []

        rule {
          source_labels = ["__journal__systemd_unit"]
          target_label  = "unit"
        }
        rule {
          source_labels = ["__journal__hostname"]
          target_label  = "node"
        }
        rule {
          source_labels = ["__journal_priority_keyword"]
          target_label  = "level"
        }
      }

      loki.source.journal "node" {
        path          = "/var/log/journal"
        max_age       = "24h"
        relabel_rules = loki.relabel.journal.rules
        labels        = { job = "node/journal" }
        forward_to    = [loki.write.default.receiver]
      }

  # Node name for the pod field selector above
  extraEnv:
    - name: NODE_NAME
      valueFrom:
        fieldRef:
          fieldPath: spec.nodeName
  # Root is needed to read /var/log/pods and the journal on the host
  securityContext:
    runAsUser: 0
    runAsGroup: 0
  mounts:
    varlog: true                   # /var/log/pods and /var/log/journal
    extra:
      - name: machine-id
        mountPath: /etc/machine-id
        readOnly: true
  resources:
    requests: { cpu: 50m, memory: 96Mi }
    limits:   { memory: 256Mi }

controller:
  type: daemonset
  tolerations:
    - operator: Exists             # also run on the (tainted) control plane
  volumes:
    extra:
      - name: machine-id
        hostPath:
          path: /etc/machine-id
          type: File
YAML

echo "[obs] installing Alloy (pod logs + node journal)"
helm upgrade --install alloy grafana/alloy -n "$NS" \
    ${ALLOY_VERSION:+--version "$ALLOY_VERSION"} \
    -f "$WORK/alloy-values.yaml" --wait --timeout 10m

# --- 4. Grafana Alloy: Kubernetes events (single replica) ------------------
cat > "$WORK/alloy-events-values.yaml" <<YAML
alloy:
  configMap:
    create: true
    content: |
      loki.write "default" {
        endpoint {
          url = "${LOKI_URL}/loki/api/v1/push"
        }
        external_labels = { cluster = "${CLUSTER_NAME}" }
      }

      // Every Kubernetes event (scheduling, pulls, OOMKills, probes, ...) in all namespaces
      loki.source.kubernetes_events "cluster" {
        job_name   = "integrations/kubernetes/eventhandler"
        log_format = "logfmt"
        forward_to = [loki.write.default.receiver]
      }
  resources:
    requests: { cpu: 20m, memory: 64Mi }
    limits:   { memory: 128Mi }

controller:
  type: deployment
  replicas: 1
YAML

echo "[obs] installing Alloy (Kubernetes events)"
helm upgrade --install alloy-events grafana/alloy -n "$NS" \
    ${ALLOY_VERSION:+--version "$ALLOY_VERSION"} \
    -f "$WORK/alloy-events-values.yaml" --wait --timeout 10m

# --- 5. Logs dashboard for Grafana (picked up by the dashboard sidecar) ------
if [ -f "$DASHBOARD_JSON" ]; then
    kubectl -n "$NS" create configmap k8s-logs-dashboard \
        --from-file=k8s-logs.json="$DASHBOARD_JSON" --dry-run=client -o yaml \
      | kubectl label --local -f - grafana_dashboard=1 -o yaml \
      | kubectl apply -f -
fi

# --- 6. Summary --------------------------------------------------------------
kubectl -n "$NS" get pods -o wide
kubectl -n "$NS" get pvc
kubectl -n "$NS" get ingress

cat <<EOF

[obs] Observability stack ready
  Grafana     http://grafana.${OBS_DOMAIN}/      user: admin  password: in ./.grafana-admin-password
  Prometheus  http://prometheus.${OBS_DOMAIN}/
  Logs        Grafana > Dashboards > "Kubernetes Logs (Loki)"   or   Explore > Loki
EOF

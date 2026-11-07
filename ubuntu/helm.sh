#!/usr/bin/env bash
# Install the Helm CLI on the control plane from the official release tarball
# (get.helm.sh), verify its SHA-256, enable bash completion and, optionally,
# add chart repositories for the vagrant user. Idempotent.
set -euo pipefail

HELM_VERSION="${HELM_VERSION:-}"   # e.g. v4.3.0; empty = latest GitHub release
HELM_REPOS="${HELM_REPOS:-}"       # optional "name=url,name=url"
ARCH="$(dpkg --print-architecture)" # amd64 / arm64 (same names Helm uses)

# 1. Resolve "latest" from the GitHub release redirect (no API rate limits)
if [ -z "$HELM_VERSION" ]; then
    HELM_VERSION="$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/helm/helm/releases/latest | sed 's#.*/tag/##')"
fi
[[ "$HELM_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+ ]] \
    || { echo "[helm] could not determine Helm version (got '${HELM_VERSION}')" >&2; exit 1; }

# 2. Install unless that exact version is already there
CURRENT="$(helm version --template '{{.Version}}' 2>/dev/null || true)"
if [ "$CURRENT" = "$HELM_VERSION" ]; then
    echo "[helm] ${HELM_VERSION} already installed"
else
    echo "[helm] installing ${HELM_VERSION} (${ARCH}) ${CURRENT:+replacing ${CURRENT}}"
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
    TARBALL="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"

    curl -fsSL -o "${TMP}/${TARBALL}"        "https://get.helm.sh/${TARBALL}"
    curl -fsSL -o "${TMP}/${TARBALL}.sha256sum" "https://get.helm.sh/${TARBALL}.sha256sum"
    (cd "$TMP" && sha256sum -c "${TARBALL}.sha256sum")   # aborts on mismatch (set -e)

    tar -xzf "${TMP}/${TARBALL}" -C "$TMP"
    install -m 0755 "${TMP}/linux-${ARCH}/helm" /usr/local/bin/helm
fi

# 3. Bash completion for every user
helm completion bash > /etc/bash_completion.d/helm

# 4. Optional chart repositories, added as the vagrant user (that's who runs
#    helm with ~/.kube/config)
if [ -n "$HELM_REPOS" ]; then
    IFS=',' read -ra REPOS <<< "$HELM_REPOS"
    for entry in "${REPOS[@]}"; do
        name="${entry%%=*}"; url="${entry#*=}"
        [ -n "$name" ] && [ -n "$url" ] && [ "$name" != "$entry" ] \
            || { echo "[helm] skipping malformed repo entry '${entry}' (use name=url)" >&2; continue; }
        sudo -u vagrant -H helm repo add --force-update "$name" "$url"
    done
    sudo -u vagrant -H helm repo update
fi

# 5. Smoke test against the cluster: the vagrant user's kubeconfig on kplane,
#    or $KUBECONFIG (e.g. /vagrant/admin.conf) on a worker.
echo "[helm] $(helm version --short)"
if [ -f /home/vagrant/.kube/config ]; then
    sudo -u vagrant -H helm list -A
elif [ -n "${KUBECONFIG:-}" ] && [ -f "$KUBECONFIG" ]; then
    helm list -A
else
    echo "[helm] no kubeconfig on this node, skipping 'helm list'"
fi

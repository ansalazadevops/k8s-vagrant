#!/usr/bin/env bash
# 1. Add the node's static IPv6 address to the host-only NIC (netplan).
# 2. Write a static /etc/hosts for the cluster.
# No IP discovery needed: every node's IPs are fixed in the Vagrantfile.
set -euo pipefail

: "${NODE_IP:?NODE_IP must be set}"
: "${NODE_IPV6:?NODE_IPV6 must be set}"
: "${CLUSTER_HOSTS:?CLUSTER_HOSTS must be set}"
IPV6_PREFIX="${IPV6_PREFIX:-64}"
HOST="$(hostname)"

# --- IPv6 on the host-only interface ----------------------------------------
# Find the NIC Vagrant gave the IPv4 address to (eth1 / enp0s8 depending on box).
IFACE="$(ip -o -4 addr show | awk -v ip="$NODE_IP" '{ split($4, a, "/"); if (a[1] == ip) print $2 }' | head -n1)"
[ -n "$IFACE" ] || { echo "[setup-hosts] no interface has ${NODE_IP}"; ip -br addr; exit 1; }

sysctl -qw "net.ipv6.conf.all.disable_ipv6=0" "net.ipv6.conf.default.disable_ipv6=0" "net.ipv6.conf.${IFACE}.disable_ipv6=0"

# Netplan merges files: this one only appends the IPv6 address to the
# interface Vagrant already declared in 50-vagrant.yaml.
NETPLAN=/etc/netplan/60-k8s-ipv6.yaml
cat > "$NETPLAN" <<YAML
network:
  version: 2
  ethernets:
    ${IFACE}:
      accept-ra: false
      addresses:
        - "${NODE_IPV6}/${IPV6_PREFIX}"
YAML
chmod 600 "$NETPLAN"
chmod 600 /etc/netplan/*.yaml 2>/dev/null || true   # silence netplan permission warnings
netplan apply

# Wait for the address to finish duplicate address detection
for _ in $(seq 1 30); do
    ip -6 addr show dev "$IFACE" | grep -q "${NODE_IPV6}/${IPV6_PREFIX}" \
      && ! ip -6 addr show dev "$IFACE" tentative | grep -q "$NODE_IPV6" && break
    sleep 1
done
ip -6 addr show dev "$IFACE" | grep -q "${NODE_IPV6}/${IPV6_PREFIX}" \
    || { echo "[setup-hosts] IPv6 ${NODE_IPV6} not configured on ${IFACE}"; exit 1; }
ip -4 addr show dev "$IFACE" | grep -q "${NODE_IP}/" \
    || { echo "[setup-hosts] IPv4 ${NODE_IP} lost on ${IFACE} after netplan apply"; exit 1; }

# --- /etc/hosts ---------------------------------------------------------------
# Drop entries that map this hostname to a loopback address (added by the box /
# Vagrant). Otherwise the node's own name resolves to 127.0.x.1.
sed -i -E "/^127\.0\.[12]\.1[[:space:]].*\b${HOST}\b/d" /etc/hosts

# Replace our managed block (idempotent on re-provision)
sed -i '/^# BEGIN k8s-vagrant/,/^# END k8s-vagrant/d' /etc/hosts
{
  echo "# BEGIN k8s-vagrant"
  tr ',' '\n' <<< "$CLUSTER_HOSTS" | awk -F: 'NF==2 { printf "%-16s %s\n", $1, $2 }'
  echo "# END k8s-vagrant"
} >> /etc/hosts

# Handy for interactive use; the provisioning scripts don't rely on it.
sed -i '/^PRIMARY_IP=/d;/^PRIMARY_IPV6=/d' /etc/environment
echo "PRIMARY_IP=${NODE_IP}"     >> /etc/environment
echo "PRIMARY_IPV6=${NODE_IPV6}" >> /etc/environment

echo "[setup-hosts] ${HOST} -> ${NODE_IP}, ${NODE_IPV6} on ${IFACE}"
grep -A 100 '^# BEGIN k8s-vagrant' /etc/hosts

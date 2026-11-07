#!/usr/bin/env bash
# Point systemd-resolved at a public DNS server (idempotent).
set -euo pipefail

if ! grep -qE '^DNS=8\.8\.8\.8' /etc/systemd/resolved.conf; then
    sed -i -E 's/^#?DNS=.*/DNS=8.8.8.8/' /etc/systemd/resolved.conf
    systemctl restart systemd-resolved
fi

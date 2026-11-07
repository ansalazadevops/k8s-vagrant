#!/usr/bin/env bash
# Enable password auth so ssh-copy-id works between nodes.
#
# On Ubuntu 22.04 cloud images, /etc/ssh/sshd_config.d/60-cloudimg-settings.conf
# sets "PasswordAuthentication no". sshd uses the FIRST value it sees and the
# drop-ins are read in lexical order, so a 10-* drop-in wins over it; editing
# /etc/ssh/sshd_config alone has no effect.
set -euo pipefail

CONF=/etc/ssh/sshd_config.d/10-k8s-vagrant.conf
if [ ! -f "$CONF" ]; then
    cat > "$CONF" <<'CFG'
PasswordAuthentication yes
KbdInteractiveAuthentication yes
CFG
    systemctl restart ssh
fi

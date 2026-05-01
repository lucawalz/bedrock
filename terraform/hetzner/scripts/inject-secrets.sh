#!/usr/bin/env bash
set -euo pipefail

install -d -m 755 "etc/horizon"
printf '%s' "${HORIZON_ZEROTIER_NETWORK_ID}" > "etc/horizon/zerotier-network-id"
printf '%s' "${HORIZON_K3S_URL}"             > "etc/horizon/k3s-url"
printf '%s' "${HORIZON_K3S_TOKEN}"           > "etc/horizon/k3s-token"
chmod 600 "etc/horizon/zerotier-network-id" \
          "etc/horizon/k3s-url" \
          "etc/horizon/k3s-token"

printf '%s\n' "${HORIZON_SSH_PUBLIC_KEY}" > "etc/horizon/ssh-authorized-keys"
chmod 644 "etc/horizon/ssh-authorized-keys"

#!/usr/bin/env bash
set -euo pipefail

install -d -m 755 "etc/horizon"
printf '%s' "${HORIZON_WG_PRIVATE_KEY}"      > "etc/horizon/wg-private"
printf '%s' "${HORIZON_WG_ADDRESS}"          > "etc/horizon/wg-address"
printf '%s' "${HORIZON_WG_HUB_PUBLIC_KEY}"   > "etc/horizon/wg-hub-public-key"
printf '%s' "${HORIZON_K3S_URL}"             > "etc/horizon/k3s-url"
printf '%s' "${HORIZON_K3S_TOKEN}"           > "etc/horizon/k3s-token"
chmod 600 "etc/horizon/wg-private" \
          "etc/horizon/wg-address" \
          "etc/horizon/wg-hub-public-key" \
          "etc/horizon/k3s-url" \
          "etc/horizon/k3s-token"

printf '%s\n' "${HORIZON_SSH_PUBLIC_KEY}" > "etc/horizon/ssh-authorized-keys"
chmod 644 "etc/horizon/ssh-authorized-keys"

#!/usr/bin/env bash
set -euo pipefail

install -d -m 755 "etc/horizon"
printf '%s' "${HORIZON_HEADSCALE_PREAUTHKEY}" > "etc/horizon/ts-auth-key"
printf '%s' "${HORIZON_HEADSCALE_SERVER_URL}"  > "etc/horizon/headscale-server-url"
printf '%s' "${HORIZON_K3S_URL}"               > "etc/horizon/k3s-url"
printf '%s' "${HORIZON_K3S_TOKEN}"             > "etc/horizon/k3s-token"
chmod 600 "etc/horizon/ts-auth-key" \
          "etc/horizon/headscale-server-url" \
          "etc/horizon/k3s-url" \
          "etc/horizon/k3s-token"

printf '%s\n' "${HORIZON_SSH_PUBLIC_KEY}" > "etc/horizon/ssh-authorized-keys"
chmod 644 "etc/horizon/ssh-authorized-keys"

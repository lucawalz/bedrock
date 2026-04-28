#!/usr/bin/env bash
set -euo pipefail
root="$(mktemp -d)"
trap 'rm -rf "${root}"' EXIT

install -d -m 755 "${root}/etc/horizon"
printf '%s' "${HORIZON_HEADSCALE_PREAUTHKEY}" > "${root}/etc/horizon/ts-auth-key"
printf '%s' "${HORIZON_HEADSCALE_SERVER_URL}"  > "${root}/etc/horizon/headscale-server-url"
printf '%s' "${HORIZON_K3S_URL}"               > "${root}/etc/horizon/k3s-url"
printf '%s' "${HORIZON_K3S_TOKEN}"             > "${root}/etc/horizon/k3s-token"
chmod 600 "${root}/etc/horizon/ts-auth-key" \
          "${root}/etc/horizon/headscale-server-url" \
          "${root}/etc/horizon/k3s-url" \
          "${root}/etc/horizon/k3s-token"

install -d -m 755 "${root}/etc/ssh/authorized_keys.d"
printf '%s\n' "${HORIZON_SSH_PUBLIC_KEY}" > "${root}/etc/ssh/authorized_keys.d/root"
chmod 644 "${root}/etc/ssh/authorized_keys.d/root"

trap - EXIT
echo "${root}"

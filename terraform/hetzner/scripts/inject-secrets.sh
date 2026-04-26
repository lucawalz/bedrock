#!/usr/bin/env bash
set -euo pipefail
mkdir -p etc/horizon
printf '%s' "${TF_VAR_headscale_preauthkey}" > etc/horizon/headscale-preauthkey
printf '%s' "${TF_VAR_k3s_url}"             > etc/horizon/k3s-url
printf '%s' "${TF_VAR_k3s_token}"           > etc/horizon/k3s-token
chmod 600 etc/horizon/headscale-preauthkey etc/horizon/k3s-url etc/horizon/k3s-token

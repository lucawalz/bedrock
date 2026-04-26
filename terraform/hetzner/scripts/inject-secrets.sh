#!/usr/bin/env bash
set -euo pipefail
mkdir -p etc/horizon
printf '%s' "${TF_VAR_netbird_setup_key}" > etc/horizon/netbird-setup-key
printf '%s' "${TF_VAR_k3s_url}"           > etc/horizon/k3s-url
printf '%s' "${TF_VAR_k3s_token}"         > etc/horizon/k3s-token
chmod 600 etc/horizon/netbird-setup-key etc/horizon/k3s-url etc/horizon/k3s-token

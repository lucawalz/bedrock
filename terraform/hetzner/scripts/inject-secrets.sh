#!/usr/bin/env bash
set -euo pipefail
mkdir -p etc/horizon
printf '%s' "${TF_VAR_headscale_preauthkey}"    > etc/horizon/ts-auth-key
printf '%s' "${TF_VAR_headscale_server_url}"    > etc/horizon/headscale-server-url
printf '%s' "${TF_VAR_k3s_url}"                > etc/horizon/k3s-url
printf '%s' "${TF_VAR_k3s_token}"              > etc/horizon/k3s-token
chmod 600 etc/horizon/ts-auth-key etc/horizon/headscale-server-url etc/horizon/k3s-url etc/horizon/k3s-token

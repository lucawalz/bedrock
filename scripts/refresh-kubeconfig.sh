#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools scp kubectl yq base64

mode="${1:-oidc}"
control_plane=root@control-plane-1
remote_kubeconfig=/etc/rancher/k3s/k3s.yaml
remote_entry=default
server_url=https://10.20.0.10:6443
oidc_kubeconfig="$HOME/.kube/config"
oidc_entry=bedrock
oidc_user=bedrock-oidc
oidc_issuer_url=https://id.syslabs.dev
oidc_client_id=kubernetes
oidc_scopes=(email groups)
exec_api_version=client.authentication.k8s.io/v1
token_cache_storage=keyring

case "$mode" in
  oidc)
    kubeconfig="$oidc_kubeconfig"
    entry="$oidc_entry"
    mkdir -p "$(dirname "$kubeconfig")"
    ;;
  admin)
    kubeconfig="${2:-$(admin_kubeconfig_path)}"
    entry="$remote_entry"
    [ -d "$(dirname "$kubeconfig")" ] || fail "$(dirname "$kubeconfig") does not exist; mount the key stick or pass another path"
    ;;
  *) fail "usage: $0 [oidc | admin [path]]" ;;
esac

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

scp -q "$control_plane:$remote_kubeconfig" "$work/k3s.yaml"

extract() {
  local query="$1" out="$2" encoded
  if ! encoded="$(ENTRY="$remote_entry" yq -N -e "$query" "$work/k3s.yaml" 2>/dev/null)" \
    || ! printf '%s' "$encoded" | base64 -d > "$out" 2>/dev/null \
    || [ ! -s "$out" ]; then
    echo "$remote_kubeconfig on $control_plane has no valid $query for $remote_entry" >&2
    exit 1
  fi
}

extract '.clusters[] | select(.name == strenv(ENTRY)) | .cluster."certificate-authority-data"' "$work/ca.crt"

kube=(kubectl --kubeconfig "$kubeconfig")
"${kube[@]}" config set-cluster "$entry" \
  --server "$server_url" \
  --certificate-authority "$work/ca.crt" \
  --embed-certs=true >/dev/null

if [ "$mode" = admin ]; then
  extract '.users[] | select(.name == strenv(ENTRY)) | .user."client-certificate-data"' "$work/client.crt"
  extract '.users[] | select(.name == strenv(ENTRY)) | .user."client-key-data"' "$work/client.key"
  user="$entry"
  "${kube[@]}" config set-credentials "$user" \
    --client-certificate "$work/client.crt" \
    --client-key "$work/client.key" \
    --embed-certs=true >/dev/null
  "${kube[@]}" config set-context "$entry" --cluster "$entry" --user "$user" >/dev/null
  "${kube[@]}" config use-context "$entry" >/dev/null
else
  user="$oidc_user"
  scope_args=()
  for scope in "${oidc_scopes[@]}"; do
    scope_args+=(--exec-arg="--oidc-extra-scope=$scope")
  done
  "${kube[@]}" config set-credentials "$user" \
    --exec-api-version="$exec_api_version" \
    --exec-interactive-mode=Never \
    --exec-command=kubectl \
    --exec-arg=oidc-login \
    --exec-arg=get-token \
    --exec-arg="--oidc-issuer-url=$oidc_issuer_url" \
    --exec-arg="--oidc-client-id=$oidc_client_id" \
    "${scope_args[@]}" \
    --exec-arg="--token-cache-storage=$token_cache_storage" >/dev/null
  "${kube[@]}" config set-context "$entry" --cluster "$entry" --user "$user" >/dev/null
fi

"${kube[@]}" --context "$entry" get nodes

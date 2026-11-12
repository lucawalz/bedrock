#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools scp kubectl yq base64

control_plane=root@control-plane-1
remote_kubeconfig=/etc/rancher/k3s/k3s.yaml
entry=default
server_url=https://10.20.0.10:6443
kubeconfig="$HOME/.kube/config"

umask 077
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

scp -q "$control_plane:$remote_kubeconfig" "$work/k3s.yaml"

extract() {
  local query="$1" out="$2" encoded
  if ! encoded="$(ENTRY="$entry" yq -N -e "$query" "$work/k3s.yaml" 2>/dev/null)" \
    || ! printf '%s' "$encoded" | base64 -d > "$out" 2>/dev/null \
    || [ ! -s "$out" ]; then
    echo "$remote_kubeconfig on $control_plane has no valid $query for $entry" >&2
    exit 1
  fi
}

extract '.clusters[] | select(.name == strenv(ENTRY)) | .cluster."certificate-authority-data"' "$work/ca.crt"
extract '.users[] | select(.name == strenv(ENTRY)) | .user."client-certificate-data"' "$work/client.crt"
extract '.users[] | select(.name == strenv(ENTRY)) | .user."client-key-data"' "$work/client.key"

mkdir -p "$(dirname "$kubeconfig")"
kubectl --kubeconfig "$kubeconfig" config set-cluster "$entry" \
  --server "$server_url" \
  --certificate-authority "$work/ca.crt" \
  --embed-certs=true >/dev/null
kubectl --kubeconfig "$kubeconfig" config set-credentials "$entry" \
  --client-certificate "$work/client.crt" \
  --client-key "$work/client.key" \
  --embed-certs=true >/dev/null
kubectl --kubeconfig "$kubeconfig" config set-context "$entry" --cluster "$entry" --user "$entry" >/dev/null

kubectl --kubeconfig "$kubeconfig" --context "$entry" get nodes

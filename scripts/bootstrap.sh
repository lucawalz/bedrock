#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools kubectl helm flux yq age-keygen base64

namespace=flux-system
operator_release=kubernetes/infrastructure/controllers/flux-operator/helmrelease.yaml
operator_source=kubernetes/clusters/home/sources/helm/controlplane.yaml
instance=kubernetes/clusters/home/flux-operator/instance/fluxinstance.yaml
instance_crd=fluxinstances.fluxcd.controlplane.io
age_key_file="${SOPS_AGE_KEY_FILE:-$HOME/.config/sops/age/keys.txt}"
crd_timeout=2m
instance_timeout=10m

operator_name="$(yq -N '.metadata.name' "$operator_release")"
operator_chart="$(yq -N '.spec.chart.spec.chart' "$operator_release")"
operator_version="$(yq -N '.spec.chart.spec.version' "$operator_release")"
operator_repository="$(yq -N '.spec.url' "$operator_source")"
instance_name="$(yq -N '.metadata.name' "$instance")"
sync_url="$(yq -N '.spec.sync.url' "$instance")"
sync_secret="$(yq -N '.spec.sync.pullSecret' "$instance")"
recipient="$(yq -N '.creation_rules[0].age' .sops.yaml)"

step() {
  local answer
  echo
  echo "== $1"
  read -r -p "Run this step? [y]es, [s]kip, anything else aborts: " answer
  case "$answer" in
    y) return 0 ;;
    s) echo "Skipped."; return 1 ;;
    *) echo "Aborted."; exit 1 ;;
  esac
}

if step "Refresh the default kubeconfig entry from control-plane-1 (the cluster CA changes on a rebuild)"; then
  bash scripts/refresh-kubeconfig.sh
fi

echo
echo "Target: context $(kubectl config current-context), server $(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')"

if step "Install the $operator_chart chart $operator_version as release $operator_name in $namespace"; then
  helm upgrade --install "$operator_name" "$operator_repository/$operator_chart" \
    --version "$operator_version" \
    --namespace "$namespace" \
    --create-namespace \
    --wait
  kubectl wait --for condition=established --timeout "$crd_timeout" "crd/$instance_crd"
fi

if step "Apply the FluxInstance $instance_name from $instance"; then
  kubectl apply -f "$instance"
fi

if step "Create the sops-age secret in $namespace from $age_key_file"; then
  if ! age-keygen -y "$age_key_file" | grep -qxF "$recipient"; then
    echo "$age_key_file holds no identity for the .sops.yaml recipient $recipient" >&2
    exit 1
  fi
  kubectl -n "$namespace" create secret generic sops-age \
    --from-file=age.agekey="$age_key_file" \
    --dry-run=client -o yaml | kubectl apply -f -
fi

if step "Create the sync secret $sync_secret for $sync_url with a new SSH deploy key"; then
  flux create secret git "$sync_secret" --namespace "$namespace" --url "$sync_url"
  echo "Add this public key to the repository as a deploy key with write access (image automation pushes to main):"
  kubectl -n "$namespace" get secret "$sync_secret" -o jsonpath='{.data.identity\.pub}' | base64 -d
fi

if step "Wait up to $instance_timeout for the FluxInstance $instance_name to become Ready"; then
  kubectl -n "$namespace" wait "fluxinstance/$instance_name" --for condition=Ready --timeout "$instance_timeout"
fi

echo
echo "Follow the reconcile with: flux get kustomizations --watch"

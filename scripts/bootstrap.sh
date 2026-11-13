#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools kubectl helm flux yq age-keygen base64

namespace=flux-system
operator_release=kubernetes/infrastructure/controllers/flux-operator/helmrelease.yaml
operator_source=kubernetes/clusters/home/sources/helm/controlplane.yaml
instance=kubernetes/clusters/home/flux-operator/instance/fluxinstance.yaml
instance_crd=fluxinstances.fluxcd.controlplane.io
age_key_file="${SOPS_AGE_KEY_FILE:-/Volumes/bedrock-keys/bedrock/age-keys.txt}"
deploy_key_file="${BEDROCK_DEPLOY_KEY:-}"
deploy_key_title=flux-home-cluster
context=default
admin_kubeconfig="$(admin_kubeconfig_path)"
coredns=kubernetes/infrastructure/controllers/coredns
coredns_timeout=2m
crd_timeout=2m
instance_timeout=10m

operator_name="$(yq -N '.metadata.name' "$operator_release")"
operator_chart="$(yq -N '.spec.chart.spec.chart' "$operator_release")"
operator_version="$(yq -N '.spec.chart.spec.version' "$operator_release")"
operator_repository="$(yq -N '.spec.url' "$operator_source")"
instance_name="$(yq -N '.metadata.name' "$instance")"
sync_url="$(yq -N '.spec.sync.url' "$instance")"
sync_secret="$(yq -N '.spec.sync.pullSecret' "$instance")"
sync_repository="${sync_url#ssh://git@github.com/}"
recipients="$(yq -N '.creation_rules[0].age' .sops.yaml)"

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

if step "Write the break-glass admin kubeconfig $admin_kubeconfig from control-plane-1 (the admin certificate changes on a rebuild)"; then
  bash scripts/refresh-kubeconfig.sh admin "$admin_kubeconfig"
fi

export KUBECONFIG="$admin_kubeconfig"
kubectl config get-contexts "$context" >/dev/null 2>&1 || { echo "$admin_kubeconfig has no context $context" >&2; exit 1; }
kube=(kubectl --context "$context")
fluxctl=(flux --context "$context")
echo
echo "Target: context $context, server $("${kube[@]}" config view --minify -o jsonpath='{.clusters[0].cluster.server}')"

# k3s runs with --disable=coredns, so a cold cluster has no DNS for Flux to fetch git until this lands
if step "Apply cluster DNS from $coredns and wait up to $coredns_timeout for the rollout"; then
  "${kube[@]}" apply --server-side -k "$coredns"
  "${kube[@]}" -n kube-system rollout status deployment/coredns --timeout "$coredns_timeout"
fi

if step "Install the $operator_chart chart $operator_version as release $operator_name in $namespace"; then
  helm upgrade --install "$operator_name" "$operator_repository/$operator_chart" \
    --version "$operator_version" \
    --namespace "$namespace" \
    --create-namespace \
    --wait \
    --kube-context "$context"
  "${kube[@]}" wait --for condition=established --timeout "$crd_timeout" "crd/$instance_crd"
fi

if step "Apply the FluxInstance $instance_name from $instance"; then
  "${kube[@]}" apply -f "$instance"
fi

if step "Create the sops-age secret in $namespace from $age_key_file"; then
  if ! age_key_matches_recipients "$age_key_file" "$recipients"; then
    echo "$age_key_file holds no identity for any .sops.yaml recipient: $recipients" >&2
    exit 1
  fi
  "${kube[@]}" -n "$namespace" create secret generic sops-age \
    --from-file=age.agekey="$age_key_file" \
    --dry-run=client -o yaml | "${kube[@]}" apply -f -
fi

if [ -n "$deploy_key_file" ]; then
  if step "Create the sync secret $sync_secret for $sync_url from the existing deploy key $deploy_key_file"; then
    [ -r "$deploy_key_file" ] || { echo "$deploy_key_file is not readable" >&2; exit 1; }
    "${fluxctl[@]}" create secret git "$sync_secret" --namespace "$namespace" --url "$sync_url" --private-key-file "$deploy_key_file"
  fi
elif step "Create the sync secret $sync_secret for $sync_url with a new SSH deploy key (set BEDROCK_DEPLOY_KEY to reuse one)"; then
  "${fluxctl[@]}" create secret git "$sync_secret" --namespace "$namespace" --url "$sync_url"
  public_key="$("${kube[@]}" -n "$namespace" get secret "$sync_secret" -o jsonpath='{.data.identity\.pub}' | base64 -d)"
  echo "$public_key"
  if step "Register this public key on $sync_repository as the read-only deploy key $deploy_key_title (delete the previous cluster's key by hand)"; then
    require_tools gh
    gh repo deploy-key add - --repo "$sync_repository" --title "$deploy_key_title" <<< "$public_key"
  fi
fi

if step "Wait up to $instance_timeout for the FluxInstance $instance_name to become Ready"; then
  "${kube[@]}" -n "$namespace" wait "fluxinstance/$instance_name" --for condition=Ready --timeout "$instance_timeout"
fi

echo
echo "Follow the reconcile with: KUBECONFIG=$admin_kubeconfig flux --context $context get kustomizations --watch"

#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools yq kustomize

k8s_dir=kubernetes
rendered_releases="${1:-}"
routable_label=bedrock.io/traefik-routable
traefik_namespace=traefik
reloader_release=reloader/reloader
traefik_release=traefik/traefik
traefik_providers=(kubernetesCRD kubernetesIngress)

reloader_missing="Namespaces with Reloader-annotated workloads that Reloader does not watch:"
reloader_dangling="Namespaces Reloader watches that hold no Reloader-annotated workload:"
traefik_missing="Namespaces holding Traefik routes or middlewares that this Traefik provider does not watch:"
traefik_dangling="Namespaces this Traefik provider watches that hold no Traefik route or middleware:"
egress_missing="Namespaces holding Traefik routes whose Namespace lacks $routable_label, so allow-traefik-egress blocks them:"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

if [ -z "$rendered_releases" ]; then
  rendered_releases="$work/rendered"
  if ! RENDER_OUTPUT_DIR="$rendered_releases" scripts/render-helm-releases.sh > "$work/render.log" 2>&1; then
    cat "$work/render.log" >&2
    fail "render-helm-releases.sh failed"
  fi
fi

: > "$work/built.yaml"
while IFS= read -r path; do
  printf -- '---\n' >> "$work/built.yaml"
  kustomize build "$path" >> "$work/built.yaml"
done < <(flux_kustomization_paths "$k8s_dir")
for release in "$rendered_releases"/*.yaml; do
  printf -- '---\n' >> "$work/built.yaml"
  cat "$release" >> "$work/built.yaml"
done

release_values() {
  RELEASE="$2" yq -N "select(.kind == \"HelmRelease\" and .metadata.namespace + \"/\" + .metadata.name == strenv(RELEASE)) | $3 | .[]" "$1" | sort -u
}

check_lists() {
  local manifests="$1" sets="$2" provider
  mkdir -p "$sets"
  status=0

  yq -N '
    select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet")
    | select((.metadata.annotations // {}) + (.spec.template.metadata.annotations // {}) | keys | any_c(test("^reloader\\.stakater\\.com/")))
    | .metadata.namespace' "$manifests" | sort -u > "$sets/annotated"
  release_values "$manifests" "$reloader_release" .spec.values.reloader.namespaces > "$sets/reloader"
  compare_sets "$sets/annotated" "$sets/reloader" "$reloader_missing" "$reloader_dangling"

  yq -N '
    select(.kind == "IngressRoute" or .kind == "IngressRouteTCP" or .kind == "IngressRouteUDP" or .kind == "Middleware" or .kind == "TraefikService" or .kind == "Ingress")
    | .metadata.namespace' "$manifests" | sort -u > "$sets/routed"
  for provider in "${traefik_providers[@]}"; do
    release_values "$manifests" "$traefik_release" ".spec.values.providers.$provider.namespaces" > "$sets/$provider"
    compare_sets "$sets/routed" "$sets/$provider" "$provider: $traefik_missing" "$provider: $traefik_dangling"
  done

  LABEL="$routable_label" yq -N 'select(.kind == "Namespace" and .metadata.labels[strenv(LABEL)] == "true") | .metadata.name' \
    "$manifests" | sort -u > "$sets/routable"
  grep -vxF "$traefik_namespace" "$sets/routed" | comm -23 - "$sets/routable" > "$sets/blocked" || true
  if [ -s "$sets/blocked" ]; then
    echo "$egress_missing"
    sed 's/^/  - /' "$sets/blocked"
    status=1
  fi

  return "$status"
}

check_lists "$work/built.yaml" "$work/present" || exit 1

dropped_watch="$(yq -N 'select(.kind == "HelmRelease" and .metadata.name == "reloader") | .spec.values.reloader.namespaces[0]' "$work/built.yaml")"
dropped_route="$(grep -vxF "$traefik_namespace" "$work/present/routed" | head -n 1)"
WATCH="$dropped_watch" ROUTE="$dropped_route" LABEL="$routable_label" yq '
  (select(.kind == "HelmRelease" and .metadata.name == "reloader") | .spec.values.reloader.namespaces) |= map(select(. != strenv(WATCH)))
  | (select(.kind == "HelmRelease" and .metadata.name == "traefik") | .spec.values.providers[].namespaces) |= map(select(. != strenv(ROUTE)))
  | del(select(.kind == "Namespace" and .metadata.name == strenv(ROUTE)) | .metadata.labels[strenv(LABEL)])
' "$work/built.yaml" > "$work/dropped.yaml"

expected="$reloader_missing
  - $dropped_watch
kubernetesCRD: $traefik_missing
  - $dropped_route
kubernetesIngress: $traefik_missing
  - $dropped_route
$egress_missing
  - $dropped_route"
if actual="$(check_lists "$work/dropped.yaml" "$work/dropped")"; then
  fail "the check passes with $dropped_watch dropped from Reloader and $dropped_route dropped from Traefik"
fi
[ "$actual" = "$expected" ] || fail "with $dropped_watch and $dropped_route dropped, the check reported:"$'\n'"$actual"

echo "Reloader and Traefik namespace lists are complete, and dropping $dropped_watch and $dropped_route fails the check."

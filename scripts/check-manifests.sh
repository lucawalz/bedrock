#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

for tool in kubeconform yq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is not on PATH; enter the dev shell or install it" >&2
    exit 1
  fi
done

k8s_dir=kubernetes
kubernetes_version="${KUBECONFORM_KUBERNETES_VERSION:-1.35.0}"
derived_schemas="${1:-}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

find "$k8s_dir" -name kustomization.yaml | sort > "$work/kustomizations"

# A kustomize patch is a fragment of a resource, so it never satisfies that resource's schema.
: > "$work/patches"
while IFS= read -r kustomization; do
  directory="$(dirname "$kustomization")"
  while IFS= read -r patch; do
    [ -n "$patch" ] || continue
    printf '%s/%s\n' "$(cd "$directory" && cd "$(dirname "$patch")" && pwd)" "$(basename "$patch")" >> "$work/patches"
  done < <(yq -N '.patches[]?.path // ""' "$kustomization" </dev/null)
done < "$work/kustomizations"
sort -u -o "$work/patches" "$work/patches"

find "$k8s_dir" -name '*.yaml' \
  ! -path "*/flux-system/gotk-components.yaml" \
  ! -name '*.sops.yaml' \
  | sort > "$work/candidates"

: > "$work/manifests"
while IFS= read -r file; do
  grep -qxF "$PWD/$file" "$work/patches" && continue
  # Collected rather than piped into grep, so a short-circuiting reader cannot SIGPIPE yq mid-file.
  declares_kind="$(yq -N 'has("kind")' "$file" </dev/null)"
  case "$declares_kind" in
    # Helm values and kustomize configuration live beside manifests and declare no resource.
    *true*) printf '%s\n' "$file" >> "$work/manifests" ;;
  esac
done < "$work/candidates"

schema_locations=(-schema-location default)
if [ -n "$derived_schemas" ]; then
  schema_locations+=(-schema-location "$derived_schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")
fi
if [ -n "${KUBECONFORM_SCHEMA_LOCATION:-}" ]; then
  schema_locations+=(-schema-location "$KUBECONFORM_SCHEMA_LOCATION")
fi

skipped="$(comm -23 "$work/candidates" "$work/manifests")"
if [ -n "$skipped" ]; then
  echo "Not manifests, skipped:"
  printf '%s\n' "$skipped" | sed 's/^/  /'
fi

xargs -a "$work/manifests" kubeconform \
  -strict \
  -ignore-missing-schemas \
  "${schema_locations[@]}" \
  -kubernetes-version "$kubernetes_version" \
  -summary

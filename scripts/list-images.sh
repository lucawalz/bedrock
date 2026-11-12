#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools yq kustomize helm

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

RENDER_OUTPUT_DIR="$work/rendered" bash scripts/render-helm-releases.sh > /dev/null

flux_kustomization_paths kubernetes > "$work/paths"
while IFS= read -r path; do
  printf -- '---\n' >> "$work/built.yaml"
  kustomize build "$path" >> "$work/built.yaml"
done < "$work/paths"

images="$(workload_images "$work/built.yaml" "$work"/rendered/*.yaml "$work"/rendered/hooks/*.yaml | sort -u)"
[ -n "$images" ] || fail "no images found"
printf '%s\n' "$images"

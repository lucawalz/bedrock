#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools yq kustomize helm

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

RENDER_OUTPUT_DIR="$work/rendered" bash scripts/render-helm-releases.sh > /dev/null

mkdir "$work/raw"
index=0
while read -r file; do
  index=$((index + 1))
  kustomize build "$(dirname "$file")" > "$work/raw/$index.yaml"
done < <(find kubernetes -name kustomization.yaml)

# shellcheck disable=SC2016
yq -N '
  select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob" or .kind == "Pod")
  | (.spec.jobTemplate.spec.template.spec // .spec.template.spec // .spec) as $pod
  | (($pod.initContainers // []) + ($pod.containers // []))[]
  | .image
' "$work"/raw/*.yaml "$work"/rendered/*.yaml "$work"/rendered/hooks/*.yaml
yq -N 'select(.apiVersion == "monitoring.coreos.com/*" and .spec.image != null) | .spec.image' \
  "$work"/raw/*.yaml "$work"/rendered/*.yaml
yq -N 'select(.apiVersion == "postgresql.cnpg.io/*" and .spec.imageName != null) | .spec.imageName' \
  "$work"/raw/*.yaml "$work"/rendered/*.yaml

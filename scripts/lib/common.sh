#!/usr/bin/env bash

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root" || exit 1

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

require_tools() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "$tool is not on PATH; enter the dev shell or install it" >&2
      exit 1
    fi
  done
}

# shellcheck disable=SC2034
compare_sets() {
  local present="$1" listed="$2" missing_message="$3" dangling_message="$4"
  local missing dangling

  missing="$(comm -23 "$present" "$listed")"
  if [ -n "$missing" ]; then
    echo "$missing_message"
    printf '%s\n' "$missing" | sed 's/^/  - /'
    status=1
  fi

  dangling="$(comm -13 "$present" "$listed")"
  if [ -n "$dangling" ]; then
    echo "$dangling_message"
    printf '%s\n' "$dangling" | sed 's/^/  - /'
    status=1
  fi
}

flux_kustomization_paths() {
  grep -rl "kustomize.toolkit.fluxcd.io" "$1" --include="*.yaml" \
    | xargs yq -N 'select(.kind == "Kustomization" and .apiVersion == "kustomize.toolkit.fluxcd.io/v1") | .spec.path' \
    | grep "^\./$1/" | sort -u
}

# shellcheck disable=SC2016
workload_images() {
  yq -N '
    (select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob" or .kind == "Pod")
      | (.spec.jobTemplate.spec.template.spec // .spec.template.spec // .spec) as $pod
      | (($pod.initContainers // []) + ($pod.containers // []))[]
      | .image),
    (select(.apiVersion == "monitoring.coreos.com/*" and .spec.image != null) | .spec.image),
    (select(.apiVersion == "postgresql.cnpg.io/*" and .spec.imageName != null) | .spec.imageName)
  ' "$@"
}

admin_kubeconfig_path() {
  printf '%s\n' "${BEDROCK_ADMIN_KUBECONFIG:-/Volumes/bedrock-keys/bedrock/kubeconfig-admin.yaml}"
}

age_key_matches_recipients() {
  local key_file="$1" recipients="$2" public_key
  public_key="$(age-keygen -y "$key_file")" || return 1
  tr -d ' \n' <<< "$recipients" | tr ',' '\n' | grep -qxF "$public_key"
}

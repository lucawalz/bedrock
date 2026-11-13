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

# k3s hashes the DER of the root certificate when the served CA bundle holds a chain.
k3s_ca_hash() {
  openssl x509 -in "$1" -outform DER | openssl dgst -sha256 -r | cut -d' ' -f1
}

admin_kubeconfig_path() {
  printf '%s\n' "${BEDROCK_ADMIN_KUBECONFIG:-/Volumes/bedrock-keys/bedrock/kubeconfig-admin.yaml}"
}

age_key_matches_recipients() {
  local key_file="$1" recipients="$2" public_key
  public_key="$(age-keygen -y "$key_file")" || return 1
  tr -d ' \n' <<< "$recipients" | tr ',' '\n' | grep -qxF "$public_key"
}

rebuild_keys_dir() {
  printf '%s/rebuild-keys\n' "$(stick_root)"
}

stick_root() {
  printf '%s\n' "${BEDROCK_STICK_ROOT:-/Volumes/bedrock-keys/bedrock}"
}

open_ssh_session() {
  local name="$1" persist="$2"
  ssh_session_dir="$(mktemp -d "/tmp/$name.XXXXXX")"
  ssh_session_options=(
    "IdentityAgent=$HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
    "IdentityFile=$repo_root/hosts/common/estate-root.pub"
    IdentitiesOnly=yes
    ControlMaster=auto
    "ControlPath=$ssh_session_dir/%C"
    "ControlPersist=$persist"
  )
}

close_ssh_session() {
  local target="$1" option args=()
  for option in "${ssh_session_options[@]}"; do args+=(-o "$option"); done
  ssh "${args[@]}" -O exit "$target" 2>/dev/null || true
  rm -rf "$ssh_session_dir"
}

node_address() {
  nix eval --raw --file "$repo_root/lib/inventory.nix" --apply \
    'inventory: builtins.concatStringsSep "\n" (builtins.attrValues (builtins.mapAttrs (name: node: name + " " + node.address) inventory.nodes))' \
    | awk -v node="$1" '$1 == node { print $2 }'
}

secret_rules() {
  nix eval --json --file "$repo_root/secrets/secrets.nix"
}

secret_recipients() {
  jq -r --arg file "$2" '.[$file].publicKeys[]' <<< "$1"
}

age_stanza_count() {
  awk '/^---/ { exit } /^-> / { count++ } END { print count + 0 }' "$1"
}

stick_host_key() {
  printf '%s/hosts/%s/etc/ssh/ssh_host_ed25519_key\n' "$(rebuild_keys_dir)" "$1"
}

stick_hosts() {
  find "$(rebuild_keys_dir)/hosts" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

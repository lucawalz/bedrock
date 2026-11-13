#!/usr/bin/env bash

fixture_host_keys() {
  local dir="$1" host
  shift
  for host in "$@"; do
    mkdir -p "$dir/hosts/$host/etc/ssh"
    ssh-keygen -q -t ed25519 -N "" -C "root@$host" -f "$dir/hosts/$host/etc/ssh/ssh_host_ed25519_key"
  done
}

fixture_rules() {
  local bindings="$1" template="$2" out="$3" binding name expression=()
  for binding in "$bindings"/*.pub; do
    name="$(basename "$binding" .pub)"
    expression+=(-e "s|^  $name = \".*\";\$|  $name = \"$(cat "$binding")\";|")
  done
  sed "${expression[@]}" "$template" > "$out"
}

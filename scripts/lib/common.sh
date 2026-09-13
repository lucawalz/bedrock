#!/usr/bin/env bash

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root" || exit 1

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

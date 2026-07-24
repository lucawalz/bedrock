#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rules_dir="$here/../../kubernetes/infrastructure/controllers/observability/alert-rules"

promtool="$(nix build 'nixpkgs#prometheus.cli' --no-link --print-out-paths)/bin/promtool"

for name in slo-blog gap-filler; do
  case "$name" in
  slo-blog) src="$rules_dir/slo-blog.yaml" ;;
  gap-filler) src="$rules_dir/prometheusrule.yaml" ;;
  esac

  gen="$here/$name-rules.gen.yaml"
  nix shell nixpkgs#yq-go -c yq '.spec' "$src" >"$gen"
  "$promtool" check rules "$gen"
  "$promtool" test rules "$here/${name}_test.yaml"
done

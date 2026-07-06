#!/usr/bin/env bash
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
rule="$here/../../kubernetes/fleet/observability/alert-rules/slo-blog.yaml"
gen="$here/slo-blog-rules.gen.yaml"

nix shell nixpkgs#yq-go -c yq '.spec' "$rule" > "$gen"

promtool="$(nix build 'nixpkgs#prometheus.cli' --no-link --print-out-paths)/bin/promtool"
"$promtool" check rules "$gen"
"$promtool" test rules "$here/slo-blog_test.yaml"

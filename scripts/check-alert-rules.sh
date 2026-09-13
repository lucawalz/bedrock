#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools promtool yq

rules_dir=kubernetes/infrastructure/controllers/observability/alert-rules
tests_dir=tests/promtool

for pair in slo-blog:slo-blog.yaml gap-filler:prometheusrule.yaml; do
  name="${pair%%:*}"
  src="$rules_dir/${pair#*:}"

  gen="$tests_dir/$name-rules.gen.yaml"
  yq '.spec' "$src" >"$gen"
  promtool check rules "$gen"
  promtool test rules "$tests_dir/${name}_test.yaml"
done

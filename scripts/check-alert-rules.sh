#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

for tool in promtool yq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is not on PATH; enter the dev shell or install it" >&2
    exit 1
  fi
done

rules_dir=kubernetes/infrastructure/controllers/observability/alert-rules
tests_dir=tests/promtool

for name in slo-blog gap-filler; do
  case "$name" in
  slo-blog) src="$rules_dir/slo-blog.yaml" ;;
  gap-filler) src="$rules_dir/prometheusrule.yaml" ;;
  esac

  gen="$tests_dir/$name-rules.gen.yaml"
  yq '.spec' "$src" >"$gen"
  promtool check rules "$gen"
  promtool test rules "$tests_dir/${name}_test.yaml"
done

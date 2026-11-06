#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools yq

readonly REQUIRED_STRATEGY=RetryOnFailure
root="${1:-kubernetes}"

if [ ! -d "$root" ]; then
  echo "$root is not a directory" >&2
  exit 1
fi

status=0

# Chartless HelmReleases are kustomize patches, not releases.
# A rollback remediation has no target when the first install fails, which strands the release.
while IFS= read -r file; do
  is_release="$(yq -N 'select(.kind == "HelmRelease" and (.spec.chart or .spec.chartRef)) | .kind' "$file" </dev/null)"
  [ -n "$is_release" ] || continue
  for action in install upgrade; do
    strategy="$(yq -N "select(.kind == \"HelmRelease\") | .spec.$action.strategy.name" "$file" </dev/null)"
    if [ "$strategy" != "$REQUIRED_STRATEGY" ]; then
      echo "$file: spec.$action.strategy.name must be $REQUIRED_STRATEGY"
      status=1
    fi
  done
done < <(grep -rl '^kind: HelmRelease' --include='*.yaml' "$root" | sort)

if [ "$status" -eq 0 ]; then
  echo "Every HelmRelease retries on failure."
fi
exit "$status"

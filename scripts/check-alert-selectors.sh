#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

for tool in curl jq yq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "$tool is not on PATH; enter the dev shell or install it" >&2
    exit 1
  fi
done

rules_dir=kubernetes/infrastructure/controllers/observability/alert-rules
allowlist=scripts/alert-selector-allowlist.txt
prometheus_url="${PROMETHEUS_URL:-}"
port_forward_pid=""
readiness_attempts=60
local_port=19490

work="$(mktemp -d)"
cleanup() {
  [ -n "$port_forward_pid" ] && kill "$port_forward_pid" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

start_port_forward() {
  kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus "$local_port:9090" >/dev/null 2>&1 &
  port_forward_pid=$!
  prometheus_url="http://localhost:$local_port"
  local attempt=0
  # An unready port-forward answers with an empty body rather than an error, so poll for content.
  while [ "$attempt" -lt "$readiness_attempts" ]; do
    if [ -n "$(curl -sf --max-time 2 "$prometheus_url/-/ready" 2>/dev/null)" ]; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  echo "Prometheus did not become reachable at $prometheus_url" >&2
  exit 1
}

if [ -z "$prometheus_url" ]; then
  if ! command -v kubectl >/dev/null 2>&1; then
    echo "kubectl is not on PATH and PROMETHEUS_URL is unset; this gate needs cluster access" >&2
    exit 1
  fi
  start_port_forward
fi

api() {
  local path="$1"
  shift
  curl -sf --max-time 30 "$prometheus_url/api/v1/$path" "$@"
}

api rules >"$work/rules.json" || {
  echo "Could not read rules from $prometheus_url" >&2
  exit 1
}

: >"$work/allow"
if [ -f "$allowlist" ]; then
  sed 's/#.*//' "$allowlist" | awk 'NF' >"$work/allow"
fi

failures=0
report() {
  failures=$((failures + 1))
  printf '%s\n' "$1"
}

jq -r '.data.groups[].rules[].name' "$work/rules.json" | sort -u >"$work/loaded-names"
yq -N '.spec.groups[].rules[] | select(has("alert")) | .alert' "$rules_dir"/*.yaml </dev/null \
  | awk 'NF' | sort -u >"$work/declared-names"
while IFS= read -r name; do
  [ -n "$name" ] || continue
  report "$name: declared in $rules_dir but not loaded by Prometheus. An alert committed but not yet pushed or reconciled reports here; recording rules are not compared at all."
done < <(comm -23 "$work/declared-names" "$work/loaded-names")

jq -r '.data.groups[] | .name as $g | .rules[] | "\($g)/\(.name)\t\(.query)"' \
  "$work/rules.json" >"$work/loaded"

: >"$work/selectors"
while IFS=$'\t' read -r rule query; do
  [ -n "$query" ] || continue
  if ! api parse_query --data-urlencode "query=$query" >"$work/ast.json" 2>/dev/null; then
    report "$rule: Prometheus could not parse the rule expression"
    continue
  fi
  # Regex, negative and empty-string matchers are dropped rather than checked: all
  # three are written to match nothing while the estate is healthy.
  jq -r --arg rule "$rule" '
    [.. | objects | select(.type == "vectorSelector" or .type == "matrixSelector")]
    | .[]
    | (.matchers | map(select(.name == "__name__" and .type == "=")) | .[0].value // "") as $m
    | select($m != "")
    | (.matchers
       | map(select(.name != "__name__" and .type == "=" and .value != ""))
       | sort_by(.name)
       | map("\(.name)=\(.value | tojson)")
       | join(",")) as $l
    | (if $l == "" then $m else "\($m){\($l)}" end)
    | "\(.)\t\($rule)"
  ' "$work/ast.json" >>"$work/selectors"
done <"$work/loaded"

sort -u "$work/selectors" | awk -F'\t' '
  { if ($1 != prev) { if (prev != "") print prev "\t" rules; prev = $1; rules = $2 }
    else rules = rules ", " $2 }
  END { if (prev != "") print prev "\t" rules }
' >"$work/unique"

while IFS=$'\t' read -r selector rules; do
  [ -n "$selector" ] || continue
  grep -qxF "$selector" "$work/allow" && continue
  [ "$(api series -G --data-urlencode "match[]=$selector" | jq '.data | length')" -gt 0 ] \
    || report "$selector matches no series, selected by: $rules"
done <"$work/unique"

if [ "$failures" -gt 0 ]; then
  echo
  echo "$failures selectors resolve to nothing; each one is a rule that cannot fire as written." >&2
  echo "Correct the rule, or record the selector as legitimately absent in $allowlist." >&2
  exit 1
fi

echo "Every metric selector in every loaded rule resolves against live series."

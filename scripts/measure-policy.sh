#!/usr/bin/env bash
set -euo pipefail

readonly PROGRAM_NAME="measure-policy"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/measure.sh
. "${repo_root}/scripts/lib/measure.sh"
cd "$repo_root"

readonly QUANTUM_SOURCE="${repo_root}/scripts/quantum.py"
readonly QUANTUM_RUNNER="${repo_root}/scripts/run-quantum.sh"

readonly ARM_BASELINE="baseline"
readonly ARM_POLICY_A="policy-a"
readonly ARM_POLICY_B="policy-b"
readonly STRATEGY_POLICY_A="LowestPrice"
readonly STRATEGY_POLICY_B="LowestPricePerCore"

readonly DEFAULT_REGION="hel1"
readonly DEFAULT_SIZE="cx23"
readonly DEFAULT_DURATION="20m"
readonly DEFAULT_REPLICAS=1
readonly DEFAULT_PROVIDER_REF="hetzner"
readonly DEFAULT_TEARDOWN_GRACE="2m"
readonly DEFAULT_MIN_CPU=2
readonly DEFAULT_MIN_MEMORY="4Gi"
readonly DEFAULT_ARCHITECTURE="x86"
readonly DEFAULT_QUANTUM_NAMESPACE="monitoring"
readonly DEFAULT_OUT_DIR="${repo_root}/var/measure-policy-runs"

readonly SECONDS_PER_HOUR=3600
readonly TARGET_QUANTUM_SECONDS=300
readonly BOOT_BUFFER_S=180
readonly READINESS_MAX_WAIT_S=900
readonly TEARDOWN_MAX_WAIT_S=600
readonly MIN_DURATION_S=900
readonly MAX_LEASE_NAME_LENGTH=44
readonly MAX_MIN_CPU=64
readonly MAX_REPLICAS=8
readonly QUANTUM_NAME_SUFFIX="-q"
readonly PROBE_NODE_SUFFIX="-probe-node"
readonly PRIMARY_IP_TYPE="ipv4"
readonly RANDOM_SUFFIX_MODULUS=65536

readonly MONEY_DISPLAY_SCALE=1000000
readonly RATE_DISPLAY_SCALE=1000

readonly QUANTITY_PATTERN='^[0-9]+(\.[0-9]+)?(Ki|Mi|Gi|Ti|K|M|G|T)?$'

usage() {
  cat <<'USAGE'
Usage: measure-policy.sh --arm ARM [options]

Runs one M4 lease cycle: applies a CapacityLease for one arm, waits for the
burst nodes, runs the fixed synthetic quantum on them at the lease's replica
count, verifies the answer against a reference checksum, releases the lease,
and exports cost and throughput artefacts beside a measure-burst.sh timeline.

Arms:
  baseline    pins spec.size
  policy-a    spec.requirements with strategy LowestPrice
  policy-b    spec.requirements with strategy LowestPricePerCore

Every real run bills at least one instance-hour per replica. Runs are safe to
launch side by side: lease names, artefact directories and the quantum Job are
all derived from --name, and the quantum is pinned to the node names of its own
lease rather than to the pool label every burst node shares.

Options:
  --arm ARM                   baseline|policy-a|policy-b (required)
  --name NAME                 lease name (default: m4-<arm>-r<replicas>-<stamp>-<random>)
  --region REGION             default hel1
  --size SIZE                 baseline pin (default cx23)
  --min-cpu N                 policy arms, default 2
  --min-memory QUANTITY       policy arms, default 4Gi
  --architecture ARCH         x86|arm, default x86
  --cpu-type TYPE             shared|dedicated, unset by default
  --replicas N                default 1
  --duration DURATION         lease duration, default 20m
  --teardown-grace DURATION   default 2m
  --provider-ref NAME         default hetzner
  --quantum-namespace NS      default monitoring
  --shard-iterations N        override the calibrated work parameter
  --seed N                    override the fixed input
  --reference-checksum HEX    the answer every unit must agree with
  --assume-instance-type T    dry-run only, the type the cost arithmetic prices
  --out-dir DIR               artefact root (default <repo>/var/measure-policy-runs)
  --dry-run                   render, validate, price and summarise without a lease
  --render                    print the lease manifest and exit, touching no cluster
  --print-reference           print the reference checksum and exit
  --self-test                 prove the cost arithmetic and exit
  -h, --help                  show this help

The reference checksum is the answer the quantum must produce. Without
--reference-checksum the driver derives it by running scripts/quantum.py once
on this machine and caching it under the artefact root, which is both cheaper
than a boot and stronger than trusting one arm: the baseline is then checked
against it too. Passing the baseline arm's own checksum with
--reference-checksum keeps the comparison anchored on a measured run instead.
USAGE
}

arm=""
name=""
region="$DEFAULT_REGION"
size="$DEFAULT_SIZE"
min_cpu="$DEFAULT_MIN_CPU"
min_memory="$DEFAULT_MIN_MEMORY"
architecture="$DEFAULT_ARCHITECTURE"
cpu_type=""
replicas="$DEFAULT_REPLICAS"
duration="$DEFAULT_DURATION"
teardown_grace="$DEFAULT_TEARDOWN_GRACE"
provider_ref="$DEFAULT_PROVIDER_REF"
quantum_namespace="$DEFAULT_QUANTUM_NAMESPACE"
shard_iterations=""
seed=""
reference_checksum=""
assume_instance_type=""
out_dir="$DEFAULT_OUT_DIR"
dry_run=0
render_only=0
print_reference=0
self_test=0

while [ $# -gt 0 ]; do
  case "$1" in
  --arm) require_value "$@"; arm="$2"; shift 2 ;;
  --name) require_value "$@"; name="$2"; shift 2 ;;
  --region) require_value "$@"; region="$2"; shift 2 ;;
  --size) require_value "$@"; size="$2"; shift 2 ;;
  --min-cpu) require_value "$@"; min_cpu="$2"; shift 2 ;;
  --min-memory) require_value "$@"; min_memory="$2"; shift 2 ;;
  --architecture) require_value "$@"; architecture="$2"; shift 2 ;;
  --cpu-type) require_value "$@"; cpu_type="$2"; shift 2 ;;
  --replicas) require_value "$@"; replicas="$2"; shift 2 ;;
  --duration) require_value "$@"; duration="$2"; shift 2 ;;
  --teardown-grace) require_value "$@"; teardown_grace="$2"; shift 2 ;;
  --provider-ref) require_value "$@"; provider_ref="$2"; shift 2 ;;
  --quantum-namespace) require_value "$@"; quantum_namespace="$2"; shift 2 ;;
  --shard-iterations) require_value "$@"; shard_iterations="$2"; shift 2 ;;
  --seed) require_value "$@"; seed="$2"; shift 2 ;;
  --reference-checksum) require_value "$@"; reference_checksum="$2"; shift 2 ;;
  --assume-instance-type) require_value "$@"; assume_instance_type="$2"; shift 2 ;;
  --out-dir) require_value "$@"; out_dir="$2"; shift 2 ;;
  --dry-run) dry_run=1; shift ;;
  --render) render_only=1; shift ;;
  --print-reference) print_reference=1; shift ;;
  --self-test) self_test=1; shift ;;
  -h | --help) usage; exit 0 ;;
  *)
    echo "measure-policy: unknown argument: $1" >&2
    usage >&2
    exit 1
    ;;
  esac
done

billed_hours() {
  local lifetime_s="$1"
  if [ "$lifetime_s" -le 0 ]; then
    echo 1
    return 0
  fi
  echo $(((lifetime_s + SECONDS_PER_HOUR - 1) / SECONDS_PER_HOUR))
}

render_cost_json() {
  local machines_json="$1" hourly="$2" ipv4="$3" reps="$4" quanta="$5" elapsed="$6"
  jq -n \
    --argjson machines "$machines_json" \
    --argjson hourly "$hourly" \
    --argjson ipv4 "$ipv4" \
    --argjson replicas "$reps" \
    --argjson quanta "$quanta" \
    --argjson elapsed "$elapsed" \
    --argjson secondsPerHour "$SECONDS_PER_HOUR" \
    '
    ($hourly + $ipv4) as $rate
    | (($machines | map(.billedHours) | add) // 0) as $billedHours
    | (($machines | map(.lifetimeSeconds) | add) // 0) as $lifetime
    | ($billedHours * $rate) as $total
    | ($lifetime / $secondsPerHour * $rate) as $unrounded
    | ($replicas * $rate) as $spendPerHour
    | (if $elapsed > 0 then $quanta * $secondsPerHour / $elapsed else 0 end) as $quantaPerHour
    | {
        machines: $machines,
        machinesObserved: ($machines | length),
        machinesExpected: $replicas,
        costComplete: (($machines | length) == $replicas and $quanta == $replicas),
        hourlyRateNet: $hourly,
        ipv4HourlyRateNet: $ipv4,
        effectiveHourlyRateNet: $rate,
        billedHoursTotal: $billedHours,
        lifetimeSecondsTotal: $lifetime,
        totalCostNet: $total,
        unroundedCostNet: $unrounded,
        roundingPremium: (if $unrounded > 0 then $total / $unrounded else null end),
        quantaCompleted: $quanta,
        costPerQuantumNet: (if $quanta > 0 then $total / $quanta else null end),
        spendPerHourNet: $spendPerHour,
        quantaPerHour: $quantaPerHour,
        quantaPerHourPerEuroNet: (if $spendPerHour > 0 then $quantaPerHour / $spendPerHour else null end)
      }
    '
}

assert_number_close() {
  local label="$1" actual="$2" expected="$3"
  jq -n --argjson a "$actual" --argjson e "$expected" \
    'if (($a - $e) | if . < 0 then -. else . end) < 1e-9 then true else error("mismatch") end' >/dev/null 2>&1 ||
    die "self-test: ${label} expected ${expected}, got ${actual}"
  echo "measure-policy: self-test ok, ${label} = ${actual}" >&2
}

assert_integer_equals() {
  local label="$1" actual="$2" expected="$3"
  [ "$actual" = "$expected" ] || die "self-test: ${label} expected ${expected}, got ${actual}"
  echo "measure-policy: self-test ok, ${label} = ${actual}" >&2
}

synthetic_machines_json() {
  local count="$1" lifetime="$2" i entries=()
  for ((i = 0; i < count; i++)); do
    entries+=("$(jq -n --arg n "machine-${i}" --argjson l "$lifetime" --argjson h "$(billed_hours "$lifetime")" \
      '{name: $n, createdAt: "", deletedAt: "", lifetimeSeconds: $l, billedHours: $h}')")
  done
  printf '%s\n' "${entries[@]}" | jq -s '.'
}

run_self_test() {
  require_tools jq

  local minutes seconds
  for minutes in 0:1 1:1 59:1 60:1 61:2 120:2 121:3; do
    seconds=$((${minutes%%:*} * 60))
    assert_integer_equals "billed hours for ${minutes%%:*} minutes" "$(billed_hours "$seconds")" "${minutes##*:}"
  done
  assert_integer_equals "billed hours for 3600 seconds" "$(billed_hours 3600)" 1
  assert_integer_equals "billed hours for 3601 seconds" "$(billed_hours 3601)" 2

  local cx23_hourly=0.0088 ipv4_hourly=0.0008 cost
  cost=$(render_cost_json "$(synthetic_machines_json 1 612)" "$cx23_hourly" "$ipv4_hourly" 1 1 300)
  assert_integer_equals "sub-hour cx23 billed hours" "$(printf '%s' "$cost" | jq -r '.billedHoursTotal')" 1
  assert_number_close "sub-hour cx23 total" "$(printf '%s' "$cost" | jq -r '.totalCostNet')" 0.0096
  assert_number_close "sub-hour cx23 cost per quantum" "$(printf '%s' "$cost" | jq -r '.costPerQuantumNet')" 0.0096
  assert_number_close "quanta per hour per euro at 300s" "$(printf '%s' "$cost" | jq -r '.quantaPerHourPerEuroNet')" 1250

  cost=$(render_cost_json "$(synthetic_machines_json 1 3540)" "$cx23_hourly" "$ipv4_hourly" 1 1 300)
  assert_integer_equals "59 minute billed hours" "$(printf '%s' "$cost" | jq -r '.billedHoursTotal')" 1
  assert_number_close "59 minute total" "$(printf '%s' "$cost" | jq -r '.totalCostNet')" 0.0096

  cost=$(render_cost_json "$(synthetic_machines_json 1 3660)" "$cx23_hourly" "$ipv4_hourly" 1 1 300)
  assert_integer_equals "61 minute billed hours" "$(printf '%s' "$cost" | jq -r '.billedHoursTotal')" 2
  assert_number_close "61 minute total" "$(printf '%s' "$cost" | jq -r '.totalCostNet')" 0.0192

  cost=$(render_cost_json "$(synthetic_machines_json 3 612)" "$cx23_hourly" "$ipv4_hourly" 3 3 300)
  assert_integer_equals "three replica billed hours" "$(printf '%s' "$cost" | jq -r '.billedHoursTotal')" 3
  assert_number_close "three replica total" "$(printf '%s' "$cost" | jq -r '.totalCostNet')" 0.0288
  assert_number_close "three replica cost per quantum" "$(printf '%s' "$cost" | jq -r '.costPerQuantumNet')" 0.0096
  assert_number_close "three replica quanta per hour per euro" "$(printf '%s' "$cost" | jq -r '.quantaPerHourPerEuroNet')" 1250

  cost=$(render_cost_json "$(synthetic_machines_json 1 612)" 0.0250 "$ipv4_hourly" 1 1 100)
  assert_number_close "dedicated type cost per quantum" "$(printf '%s' "$cost" | jq -r '.costPerQuantumNet')" 0.0258
  assert_number_close "dedicated type quanta per hour per euro" "$(printf '%s' "$cost" | jq -r '.quantaPerHourPerEuroNet')" 1395.3488372093022

  echo "measure-policy: self-test passed" >&2
}

if [ "$self_test" -eq 1 ]; then
  run_self_test
  exit 0
fi

case "$arm" in
"$ARM_BASELINE") strategy="" ;;
"$ARM_POLICY_A") strategy="$STRATEGY_POLICY_A" ;;
"$ARM_POLICY_B") strategy="$STRATEGY_POLICY_B" ;;
"") die "--arm is required, one of: ${ARM_BASELINE} ${ARM_POLICY_A} ${ARM_POLICY_B}" ;;
*) die "unknown arm '${arm}', must be one of: ${ARM_BASELINE} ${ARM_POLICY_A} ${ARM_POLICY_B}" ;;
esac

if [ -z "$name" ]; then
  name="m4-${arm}-r${replicas}-$(date +%Y%m%d%H%M%S)-$(printf '%04x' $((RANDOM % RANDOM_SUFFIX_MODULUS)))"
fi

require_pattern --name "$name" "$DNS_LABEL_PATTERN" "a lowercase alphanumeric DNS label"
if [ "${#name}" -gt "$MAX_LEASE_NAME_LENGTH" ]; then
  die "--name must be at most ${MAX_LEASE_NAME_LENGTH} characters so the derived quantum Job name stays valid, got ${#name}"
fi
require_pattern --region "$region" "$DNS_LABEL_PATTERN" "a lowercase alphanumeric Hetzner region such as hel1"
require_pattern --size "$size" "$DNS_LABEL_PATTERN" "a lowercase alphanumeric Hetzner server type such as cx23"
require_pattern --provider-ref "$provider_ref" "$DNS_LABEL_PATTERN" "a lowercase alphanumeric object name"
require_pattern --quantum-namespace "$quantum_namespace" "$DNS_LABEL_PATTERN" "a lowercase alphanumeric DNS label"
require_pattern --replicas "$replicas" "$POSITIVE_INTEGER_PATTERN" "a positive whole number"
require_pattern --min-cpu "$min_cpu" "$POSITIVE_INTEGER_PATTERN" "a positive whole number"
require_pattern --min-memory "$min_memory" "$QUANTITY_PATTERN" "a Kubernetes quantity such as 4Gi"

if [ "$replicas" -gt "$MAX_REPLICAS" ]; then
  die "--replicas must be at most ${MAX_REPLICAS}, which is the ceiling the CapacityLease schema enforces"
fi
if [ "$min_cpu" -gt "$MAX_MIN_CPU" ]; then
  die "--min-cpu must be at most ${MAX_MIN_CPU}, which is the ceiling the CapacityLease schema enforces"
fi

case "$architecture" in
x86 | arm) ;;
*) die "--architecture must be x86 or arm, got '${architecture}'" ;;
esac

case "$cpu_type" in
"" | shared | dedicated) ;;
*) die "--cpu-type must be shared or dedicated, got '${cpu_type}'" ;;
esac

if [ -n "$shard_iterations" ]; then
  require_pattern --shard-iterations "$shard_iterations" "$POSITIVE_INTEGER_PATTERN" "a positive whole number"
fi
if [ -n "$seed" ]; then
  require_pattern --seed "$seed" "$POSITIVE_INTEGER_PATTERN" "a positive whole number"
fi
if [ -n "$reference_checksum" ]; then
  require_pattern --reference-checksum "$reference_checksum" "$SHA256_HEX_PATTERN" "a lowercase 64-character sha256 digest"
fi
if [ -n "$assume_instance_type" ]; then
  require_pattern --assume-instance-type "$assume_instance_type" "$DNS_LABEL_PATTERN" "a lowercase alphanumeric Hetzner server type"
  [ "$dry_run" -eq 1 ] || die "--assume-instance-type only applies to --dry-run; a real run reads status.instanceType"
fi

duration_s=$(parse_duration_to_seconds "$duration") || die "--duration is not a duration this harness can measure"
parse_duration_to_seconds "$teardown_grace" >/dev/null || die "--teardown-grace is not a duration this harness can measure"
if [ "$duration_s" -lt "$MIN_DURATION_S" ]; then
  die "--duration must be at least ${MIN_DURATION_S}s so a boot plus a quantum that runs long during calibration still fits inside the lease"
fi

[ -r "$QUANTUM_SOURCE" ] || die "cannot read ${QUANTUM_SOURCE}"
[ -x "$QUANTUM_RUNNER" ] || die "cannot execute ${QUANTUM_RUNNER}"

quantum_name="${name}${QUANTUM_NAME_SUFFIX}"
quantum_max_wait_s=$((duration_s - BOOT_BUFFER_S))

read_quantum_default() {
  awk -v k="$1" '$1 == k && $2 == "=" { print $3 }' "$QUANTUM_SOURCE"
}

effective_shard_iterations="${shard_iterations:-$(read_quantum_default DEFAULT_SHARD_ITERATIONS)}"
effective_seed="${seed:-$(read_quantum_default DEFAULT_SEED)}"
require_pattern "DEFAULT_SHARD_ITERATIONS in ${QUANTUM_SOURCE}" "$effective_shard_iterations" "$POSITIVE_INTEGER_PATTERN" "a positive whole number"
require_pattern "DEFAULT_SEED in ${QUANTUM_SOURCE}" "$effective_seed" "$POSITIVE_INTEGER_PATTERN" "a positive whole number"

reference_dir="${out_dir}/reference"
reference_source="flag"

# The cache is written through a temporary file so concurrent runs that all warm it cannot publish a half-written digest.
resolve_reference_checksum() {
  [ -n "$reference_checksum" ] && return 0

  local cache_path="${reference_dir}/${effective_seed}-${effective_shard_iterations}.checksum" computed temp_path
  mkdir -p "$reference_dir"
  if [ -r "$cache_path" ]; then
    reference_checksum=$(cat "$cache_path")
    if [[ "$reference_checksum" =~ $SHA256_HEX_PATTERN ]]; then
      reference_source="cache"
      return 0
    fi
    reference_checksum=""
  fi

  require_tools python3 jq
  echo "measure-policy: deriving the reference checksum locally for seed ${effective_seed} and ${effective_shard_iterations} shard iterations" >&2
  computed=$(QUANTUM_SHARD_ITERATIONS="$effective_shard_iterations" QUANTUM_SEED="$effective_seed" python3 "$QUANTUM_SOURCE" | jq -r '.checksum') ||
    die "the local reference computation failed; pass --reference-checksum instead"
  require_pattern "the locally derived reference checksum" "$computed" "$SHA256_HEX_PATTERN" "a lowercase 64-character sha256 digest"

  temp_path="${cache_path}.$$"
  printf '%s\n' "$computed" >"$temp_path" && mv -f "$temp_path" "$cache_path"
  reference_checksum="$computed"
  reference_source="computed"
}

if [ "$print_reference" -eq 1 ]; then
  resolve_reference_checksum
  echo "$reference_checksum"
  exit 0
fi

render_sizing() {
  if [ -z "$strategy" ]; then
    echo "  size: ${size}"
    return 0
  fi
  cat <<YAML
  requirements:
    architecture: ${architecture}
    minCPU: ${min_cpu}
    minMemory: "${min_memory}"
    strategy: ${strategy}
YAML
  if [ -n "$cpu_type" ]; then
    echo "    cpuType: ${cpu_type}"
  fi
}

build_lease_manifest() {
  cat <<YAML
apiVersion: horizon.dev/v1alpha1
kind: CapacityLease
metadata:
  name: ${name}
spec:
  providerRef: ${provider_ref}
  region: ${region}
  replicas: ${replicas}
  duration: ${duration}
  teardownGrace: ${teardown_grace}
$(render_sizing)
YAML
}

if [ "$render_only" -eq 1 ]; then
  build_lease_manifest
  exit 0
fi

require_tools kubectl hcloud jq curl
require_gnu_date
load_hcloud_token

run_dir="${out_dir}/${name}"
mkdir -p "$run_dir"
csv_path="${run_dir}/harness.csv"
lease_json_path="${run_dir}/lease-final.json"
operator_log_path="${run_dir}/operator.log"
hetzner_pricing_path="${run_dir}/hetzner-pricing.json"
server_types_path="${run_dir}/hetzner-server-types.json"
run_params_path="${run_dir}/run-params.json"
cost_path="${run_dir}/cost.json"
summary_path="${run_dir}/summary.txt"
quantum_run_dir="${run_dir}/${quantum_name}"
quantum_results_path="${quantum_run_dir}/results.jsonl"

lease_applied=0
lease_dumped=0
start_epoch=0
start_iso=""
operator_log_captured_until=""
quantum_outcome="not-run"
quantum_pid=""
selected_type=""

apply_lease() {
  build_lease_manifest | kubectl apply -f -
  lease_applied=1
}

export_server_types() {
  hcloud server-type list -o json >"$server_types_path"
}

probe_node_list() {
  local index list=""
  for ((index = 0; index < replicas; index++)); do
    list+="${list:+,}${name}${PROBE_NODE_SUFFIX}-${index}"
  done
  echo "$list"
}

preflight() {
  echo "measure-policy: validating the ${arm} lease manifest against the live API server, nothing persisted" >&2
  build_lease_manifest | kubectl apply --dry-run=server -f - >/dev/null

  echo "measure-policy: validating the quantum manifest against the live API server, nothing persisted" >&2
  "$QUANTUM_RUNNER" --render \
    --name "$quantum_name" \
    --namespace "$quantum_namespace" \
    --replicas "$replicas" \
    --nodes "$(probe_node_list)" \
    ${shard_iterations:+--shard-iterations "$shard_iterations"} \
    ${seed:+--seed "$seed"} |
    kubectl apply --dry-run=server -f - >/dev/null

  run_export hetzner-pricing export_hetzner_pricing
  run_export hetzner-server-types export_server_types
}

pricing_hourly_net() {
  local instance_type="$1"
  jq -r --arg t "$instance_type" --arg r "$region" \
    '.pricing.server_types[] | select(.name == $t) | .prices[] | select(.location == $r) | .price_hourly.net' \
    "$hetzner_pricing_path" 2>/dev/null | head -1
}

pricing_ipv4_hourly_net() {
  jq -r --arg t "$PRIMARY_IP_TYPE" --arg r "$region" \
    '.pricing.primary_ips[] | select(.type == $t) | .prices[] | select(.location == $r) | .price_hourly.net' \
    "$hetzner_pricing_path" 2>/dev/null | head -1
}

server_type_facts() {
  local instance_type="$1"
  jq -c --arg t "$instance_type" \
    '[.[] | select(.name == $t) | {cores, memory, cpu_type, architecture}][0] // {}' \
    "$server_types_path" 2>/dev/null
}

build_machines_json() {
  local entries=() server created_iso created_epoch deleted_epoch lifetime hours now
  now=$(date +%s)
  for server in "${!hetzner_seen[@]}"; do
    created_iso="${hetzner_created[$server]:-}"
    created_epoch=""
    if [ -n "$created_iso" ]; then
      created_epoch=$(date -u -d "$created_iso" +%s 2>/dev/null) || created_epoch=""
    fi
    [ -n "$created_epoch" ] || created_epoch="$start_epoch"
    deleted_epoch="${hetzner_absent_at[$server]:-$now}"
    lifetime=$((deleted_epoch - created_epoch))
    hours=$(billed_hours "$lifetime")
    entries+=("$(jq -n --arg n "$server" \
      --arg c "$(instant_of "$created_epoch")" \
      --arg d "$(instant_of "$deleted_epoch")" \
      --argjson l "$lifetime" --argjson h "$hours" \
      '{name: $n, createdAt: $c, deletedAt: $d, lifetimeSeconds: $l, billedHours: $h}')")
  done
  if [ "${#entries[@]}" -eq 0 ]; then
    echo '[]'
    return 0
  fi
  printf '%s\n' "${entries[@]}" | jq -s 'sort_by(.name)'
}

quantum_summary_json() {
  if [ ! -s "$quantum_results_path" ]; then
    echo '{"units":0,"checksums":[],"checksum":null,"elapsedSecondsMax":0,"elapsedSecondsMin":0,"nodes":[]}'
    return 0
  fi
  jq -s '{
    units: length,
    checksums: (map(.checksum) | unique),
    checksum: (map(.checksum) | unique | if length == 1 then .[0] else . end),
    elapsedSecondsMax: (map(.elapsedSeconds) | max),
    elapsedSecondsMin: (map(.elapsedSeconds) | min),
    nodes: (map({node: .node, workers: .workers, elapsedSeconds: .elapsedSeconds}) | sort_by(.node))
  }' "$quantum_results_path"
}

resolve_selected_type() {
  selected_type="${lease_seen[instanceType]:-}"
  if [ -z "$selected_type" ] && [ -r "$lease_json_path" ]; then
    selected_type=$(jq -r '.status.instanceType // empty' "$lease_json_path" 2>/dev/null) || selected_type=""
  fi
  if [ -z "$selected_type" ] && [ -z "$strategy" ]; then
    selected_type="$size"
  fi
}

write_cost_artefact() {
  local machines cost quantum facts hourly ipv4 elapsed units checksum suggested

  machines=$(build_machines_json)
  quantum=$(quantum_summary_json)
  units=$(printf '%s' "$quantum" | jq -r '.units')
  elapsed=$(printf '%s' "$quantum" | jq -r '.elapsedSecondsMax')
  checksum=$(printf '%s' "$quantum" | jq -r 'if (.checksum | type) == "string" then .checksum else "disagreed" end')

  hourly=$(pricing_hourly_net "$selected_type")
  ipv4=$(pricing_ipv4_hourly_net)
  facts=$(server_type_facts "$selected_type")
  if [ -z "$hourly" ] || [ -z "$ipv4" ]; then
    echo "measure-policy: WARNING no ${region} hourly rate for '${selected_type}' in the exported pricing; the cost figures below are not usable" >&2
    emit_event harness "$name" pricing-unresolved "${selected_type:-unknown}"
  fi
  [ -n "$hourly" ] || hourly=0
  [ -n "$ipv4" ] || ipv4=0
  [ -n "$facts" ] || facts='{}'

  suggested=$(jq -n --argjson it "$effective_shard_iterations" --argjson e "$elapsed" --argjson target "$TARGET_QUANTUM_SECONDS" \
    'if $e > 0 then ($it * $target / $e | round) else null end')

  cost=$(render_cost_json "$machines" "$hourly" "$ipv4" "$replicas" "$units" "$elapsed")

  jq -n \
    --argjson cost "$cost" \
    --argjson quantum "$quantum" \
    --argjson facts "$facts" \
    --arg arm "$arm" \
    --arg leaseName "$name" \
    --arg region "$region" \
    --arg strategy "$strategy" \
    --arg requestedSize "$size" \
    --arg architecture "$architecture" \
    --arg cpuType "$cpu_type" \
    --arg minMemory "$min_memory" \
    --argjson minCPU "$min_cpu" \
    --argjson replicas "$replicas" \
    --arg selectedInstanceType "$selected_type" \
    --arg currency "$(jq -r '.pricing.currency // "EUR"' "$hetzner_pricing_path" 2>/dev/null || echo EUR)" \
    --arg referenceChecksum "$reference_checksum" \
    --arg referenceSource "$reference_source" \
    --arg quantumOutcome "$quantum_outcome" \
    --arg checksum "$checksum" \
    --argjson shardIterations "$effective_shard_iterations" \
    --argjson seed "$effective_seed" \
    --argjson targetSeconds "$TARGET_QUANTUM_SECONDS" \
    --argjson suggestedShardIterations "$suggested" \
    --argjson dryRun "$([ "$dry_run" -eq 1 ] && echo true || echo false)" \
    '{
      arm: $arm,
      leaseName: $leaseName,
      region: $region,
      replicas: $replicas,
      requested: (if $strategy == "" then {size: $requestedSize} else {minCPU: $minCPU, minMemory: $minMemory, architecture: $architecture, cpuType: (if $cpuType == "" then null else $cpuType end), strategy: $strategy} end),
      selectedInstanceType: $selectedInstanceType,
      selectedCores: ($facts.cores // null),
      selectedMemoryGB: ($facts.memory // null),
      selectedCPUType: ($facts.cpu_type // null),
      selectedArchitecture: ($facts.architecture // null),
      currency: $currency,
      quantum: ($quantum + {outcome: $quantumOutcome, checksum: $checksum, referenceChecksum: $referenceChecksum, referenceSource: $referenceSource, checksumMatchesReference: ($checksum == $referenceChecksum)}),
      calibration: {shardIterations: $shardIterations, seed: $seed, targetSeconds: $targetSeconds, suggestedShardIterations: $suggestedShardIterations},
      dryRun: $dryRun
    } + $cost' >"$cost_path"
}

emit_cost_rows() {
  local field value node
  while IFS=$'\t' read -r field value; do
    [ -n "$field" ] || continue
    emit_event cost "$name" "$field" "$value"
  done < <(jq -r 'to_entries[] | select((.value | type) != "object" and (.value | type) != "array") | [.key, (.value | tostring)] | @tsv' "$cost_path")

  while IFS=$'\t' read -r node value; do
    [ -n "$node" ] || continue
    emit_event quantum "$node" elapsedSeconds "$value"
  done < <(jq -r '.quantum.nodes[]? | [.node, (.elapsedSeconds | tostring)] | @tsv' "$cost_path")

  emit_event quantum "$name" checksum "$(jq -r '.quantum.checksum' "$cost_path")"
  emit_event quantum "$name" checksumMatchesReference "$(jq -r '.quantum.checksumMatchesReference' "$cost_path")"
  emit_event calibration "$name" suggestedShardIterations "$(jq -r '.calibration.suggestedShardIterations' "$cost_path")"
}

write_run_params() {
  jq -n \
    --arg name "$name" \
    --arg arm "$arm" \
    --arg strategy "$strategy" \
    --arg region "$region" \
    --arg size "$size" \
    --arg architecture "$architecture" \
    --arg cpuType "$cpu_type" \
    --arg minMemory "$min_memory" \
    --argjson minCPU "$min_cpu" \
    --argjson replicas "$replicas" \
    --arg duration "$duration" \
    --arg teardownGrace "$teardown_grace" \
    --arg providerRef "$provider_ref" \
    --arg quantumNamespace "$quantum_namespace" \
    --arg quantumName "$quantum_name" \
    --arg referenceChecksum "$reference_checksum" \
    --arg referenceSource "$reference_source" \
    --argjson shardIterations "$effective_shard_iterations" \
    --argjson seed "$effective_seed" \
    --arg startedAt "$start_iso" \
    --argjson dryRun "$([ "$dry_run" -eq 1 ] && echo true || echo false)" \
    '$ARGS.named' >"$run_params_path"
}

write_summary() {
  {
    jq -r --argjson money "$MONEY_DISPLAY_SCALE" --argjson rate "$RATE_DISPLAY_SCALE" '
      def scaled($n): if . == null then 0 else (. * $n | round) / $n end;
      "arm            " + .arm + "  lease " + .leaseName + "  region " + .region + "  replicas " + (.replicas | tostring),
      "requested      " + (.requested | to_entries | map(.key + "=" + (.value | tostring)) | join(" ")),
      "selected       " + (.selectedInstanceType // "unknown") + "  cores " + ((.selectedCores // "?") | tostring) + "  " + ((.selectedCPUType // "?") | tostring) + "  " + ((.selectedMemoryGB // "?") | tostring) + " GB",
      "rates          " + .currency + " " + (.hourlyRateNet | tostring) + "/h server plus " + .currency + " " + (.ipv4HourlyRateNet | tostring) + "/h primary IPv4, net",
      "machines       " + (.machinesObserved | tostring) + " observed, " + (.lifetimeSecondsTotal | tostring) + "s of lifetime, " + (.billedHoursTotal | tostring) + " billed hour(s)",
      "quantum        " + (.quantum.units | tostring) + " unit(s), outcome " + .quantum.outcome + ", checksum matches reference: " + (.quantum.checksumMatchesReference | tostring),
      "elapsed        " + (.quantum.elapsedSecondsMin | tostring) + "s to " + (.quantum.elapsedSecondsMax | tostring) + "s per unit",
      "cost           " + .currency + " " + (.totalCostNet | scaled($money) | tostring) + " total, " + .currency + " " + (.costPerQuantumNet | scaled($money) | tostring) + " per quantum",
      "rounding       unrounded " + .currency + " " + (.unroundedCostNet | scaled($money) | tostring) + ", premium " + (.roundingPremium | scaled($rate) | tostring) + "x",
      "throughput     " + (.quantaPerHour | scaled($rate) | tostring) + " quanta/h, " + (.quantaPerHourPerEuroNet | scaled($rate) | tostring) + " quanta/h per " + .currency + "/h",
      "calibration    DEFAULT_SHARD_ITERATIONS " + (.calibration.shardIterations | tostring) + " -> " + ((.calibration.suggestedShardIterations // "unknown") | tostring) + " for a " + (.calibration.targetSeconds | tostring) + "s target",
      "dry run        " + (.dryRun | tostring)
    ' "$cost_path"
  } >"$summary_path"
  sed 's/^/measure-policy: /' "$summary_path" >&2
}

export_artefacts() {
  echo "measure-policy: exporting artefacts to ${run_dir}" >&2
  run_export operator-log capture_operator_log_so_far
  resolve_selected_type
  write_cost_artefact
  emit_cost_rows
  write_run_params
  write_summary
}

# Cleanup is the only guarantee that a billed server is gone, so it disables errexit and ignores the signals a closed terminal or an impatient operator sends.
cleanup() {
  local exit_code=$?
  trap - EXIT
  trap '' INT TERM HUP QUIT
  set +e

  if [ "$lease_dumped" -eq 0 ] && [ "$lease_applied" -eq 1 ]; then
    kubectl get capacitylease "$name" -o json >"$lease_json_path" 2>/dev/null
  fi

  if [ -n "$quantum_pid" ]; then
    kill "$quantum_pid" >/dev/null 2>&1
  fi

  kubectl -n "$quantum_namespace" delete job "$quantum_name" --ignore-not-found --wait=false >/dev/null 2>&1
  kubectl -n "$quantum_namespace" delete configmap "$quantum_name" --ignore-not-found >/dev/null 2>&1

  if [ "$dry_run" -eq 1 ]; then
    exit "$exit_code"
  fi

  release_lease_and_verify_estate_empty || exit_code=1

  exit "$exit_code"
}
trap cleanup EXIT INT TERM HUP

await_nodes_ready() {
  local deadline="$1"
  while :; do
    poll_all
    if [ "${#node_names[@]}" -ge "$replicas" ] && [ "$(ready_node_count)" -ge "$replicas" ]; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    sleep "$POLL_INTERVAL_S"
  done
}

# The quantum runs in the background so an interrupt reaches the cleanup trap during wait instead of queueing behind a child that may still have minutes to run.
run_quantum_on_burst_nodes() {
  local pinned
  pinned=$(printf '%s,' "${node_names[@]}")
  pinned="${pinned%,}"
  emit_event harness "$name" quantum-start "$pinned"
  echo "measure-policy: running the quantum on ${pinned} at replicas ${replicas}" >&2
  "$QUANTUM_RUNNER" \
    --name "$quantum_name" \
    --namespace "$quantum_namespace" \
    --replicas "$replicas" \
    --nodes "$pinned" \
    --expect-checksum "$reference_checksum" \
    --out-dir "$run_dir" \
    --max-wait "$quantum_max_wait_s" \
    ${shard_iterations:+--shard-iterations "$shard_iterations"} \
    ${seed:+--seed "$seed"} >&2 &
  quantum_pid=$!
  if wait "$quantum_pid"; then
    quantum_outcome="verified"
  else
    quantum_outcome="failed"
    echo "measure-policy: FINDING the quantum did not verify on ${selected_type:-the selected type}; the artefacts still record what it produced" >&2
  fi
  quantum_pid=""
  emit_event harness "$name" quantum-outcome "$quantum_outcome"
}

release_and_observe_teardown() {
  echo "measure-policy: releasing lease ${name} now that the quantum is done; the hour is already billed" >&2
  kubectl delete capacitylease "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  emit_event harness "$name" lease-released post-quantum
  if observe_until_estate_empty "$(($(date +%s) + TEARDOWN_MAX_WAIT_S))"; then
    echo "measure-policy: teardown observed at $(($(date +%s) - start_epoch))s" >&2
  else
    echo "measure-policy: WARNING no confirmed teardown within ${TEARDOWN_MAX_WAIT_S}s; cleanup still verifies the estate" >&2
  fi
}

real_run() {
  start_epoch=$(date +%s)
  start_iso=$(instant_of "$start_epoch")
  operator_log_captured_until="$start_iso"
  csv_header

  resolve_reference_checksum
  emit_event harness "$name" reference-checksum "${reference_checksum} via ${reference_source}"

  preflight

  echo "measure-policy: applying lease ${name} (arm=${arm}, region=${region}, replicas=${replicas}, duration=${duration})" >&2
  apply_lease
  emit_event harness "$name" lease-applied "$arm"

  if ! await_nodes_ready "$((start_epoch + READINESS_MAX_WAIT_S))"; then
    echo "measure-policy: FATAL ${replicas} Ready node(s) did not appear within ${READINESS_MAX_WAIT_S}s" >&2
    emit_event harness "$name" readiness-timeout "$READINESS_MAX_WAIT_S"
    kubectl get capacitylease "$name" -o json >"$lease_json_path" 2>/dev/null && lease_dumped=1
    export_artefacts
    exit 1
  fi

  resolve_selected_type
  echo "measure-policy: ${replicas} node(s) Ready at $(($(date +%s) - start_epoch))s on ${selected_type:-an unreported type}" >&2

  run_quantum_on_burst_nodes

  kubectl get capacitylease "$name" -o json >"$lease_json_path" 2>/dev/null && lease_dumped=1
  release_and_observe_teardown
  export_artefacts

  [ "$quantum_outcome" = verified ] || exit 1
}

replay_synthetic_timeline() {
  local index server node created_epoch absent_epoch
  created_epoch=$((start_epoch + 2))
  absent_epoch=$((start_epoch + 614))
  emit_event_at lease "$name" phase Pending 0
  emit_event_at lease "$name" acceptedAt "$(instant_of "$((start_epoch + 1))")" 1
  emit_event_at lease "$name" phase Provisioning 2
  emit_event_at lease "$name" instanceType "$selected_type" 3
  lease_seen[instanceType]="$selected_type"

  for ((index = 0; index < replicas; index++)); do
    server="${name}-${index}"
    node="${name}-node-${index}"
    hetzner_created[$server]="$(instant_of "$created_epoch")"
    hetzner_seen[$server]="absent"
    hetzner_absent_at[$server]="$absent_epoch"
    node_names+=("$node")
    node_seen[$node,ready]=True
    emit_event_at hetzner "$server" created "$(instant_of "$created_epoch")" 4
    emit_event_at hetzner "$server" status running 18
    emit_event_at lease "$name" nodeName "$node" 60
    emit_event_at node "$node" ready True 72
    emit_event_at hetzner "$server" status absent 614
  done

  emit_event_at lease "$name" readyAt "$(instant_of "$((start_epoch + 72))")" 72
  emit_event_at lease "$name" phase Active 72
  emit_event_at lease "$name" releasedAt "$(instant_of "$absent_epoch")" 614
  emit_event_at lease "$name" phase Released 614
}

readonly SYNTHETIC_ELAPSED_SECONDS=412.5

write_synthetic_quantum_results() {
  local index node
  mkdir -p "$quantum_run_dir"
  : >"$quantum_results_path"
  for ((index = 0; index < replicas; index++)); do
    node="${name}-node-${index}"
    jq -n -c --arg node "$node" --arg checksum "$reference_checksum" \
      --argjson elapsed "$SYNTHETIC_ELAPSED_SECONDS" \
      --argjson iterations "$effective_shard_iterations" --argjson seed "$effective_seed" \
      '{checksum: $checksum, elapsedSeconds: $elapsed, node: $node, shardIterations: $iterations, seed: $seed, workers: 2}' \
      >>"$quantum_results_path"
  done
  quantum_outcome="synthetic"
}

dry_run_flow() {
  start_epoch=$(date +%s)
  start_iso=$(instant_of "$start_epoch")
  operator_log_captured_until="$start_iso"
  csv_header

  resolve_reference_checksum
  emit_event harness "$name" reference-checksum "${reference_checksum} via ${reference_source}"

  preflight

  selected_type="${assume_instance_type:-$size}"
  echo "measure-policy: dry-run, pricing the cost arithmetic against ${selected_type}; a real run reads status.instanceType instead" >&2

  echo "measure-policy: dry-run, replaying a synthetic event timeline through the real CSV writer" >&2
  replay_synthetic_timeline
  write_synthetic_quantum_results

  jq -n --arg note "synthetic dry-run lease, never applied to the cluster" \
    --arg type "$selected_type" --arg started "$start_iso" \
    '{status: {phase: "Released", acceptedAt: $started, instanceType: $type, note: $note}}' >"$lease_json_path"
  lease_dumped=1

  export_artefacts
}

if [ "$dry_run" -eq 1 ]; then
  dry_run_flow
else
  real_run
fi

#!/usr/bin/env bash
set -euo pipefail

readonly MINIMUM_BASH_MAJOR=4
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt "$MINIMUM_BASH_MAJOR" ]; then
  echo "measure-burst: bash ${MINIMUM_BASH_MAJOR} or newer is required for associative arrays; run it inside 'nix develop', which provides one" >&2
  exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

readonly POLL_INTERVAL_S=5
readonly DEFAULT_INJECTION_OFFSET_S=30
readonly DEFAULT_TEARDOWN_GRACE="2m"
readonly DEFAULT_REPLICAS=1
readonly DEFAULT_PROVIDER_REF="hetzner"
readonly DEFAULT_OUT_DIR="${repo_root}/var/measure-burst-runs"

readonly BOOT_BUFFER_S=180
readonly TEARDOWN_BUFFER_S=300
readonly WATCHDOG_WALLCLOCK_BUFFER_S=300
readonly CLEANUP_MAX_WAIT_S=300
readonly CLEANUP_POLL_INTERVAL_S=5
readonly READINESS_SIGNAL_MAX_WAIT_S=900
readonly HETZNER_POLL_FAILURE_LIMIT=5
readonly INJECTION_JOB_MAX_WAIT_S=300
readonly OPERATOR_RESTORE_SETTLE_S=180
readonly MAX_LEASE_NAME_LENGTH=50

readonly HETZNER_SECRET_NAMESPACE="horizon-system"
readonly HETZNER_SECRET_NAME="horizon-hetzner"
readonly OPERATOR_NAMESPACE="horizon-system"
readonly OPERATOR_DEPLOYMENT="horizon"
# horizon-system enforces PodSecurity baseline and Kyverno's require-run-as-non-root, require-drop-all-capabilities and require-resources, which reject the privileged hostPID pod node access needs; monitoring is already relaxed for node-exporter's own host access.
readonly INJECTION_NAMESPACE="monitoring"
readonly LEASE_LABEL_KEY="horizon.dev/lease"
readonly BURST_TAINT_KEY="horizon.dev/burst"
readonly WATCHDOG_ARMED_ANNOTATION="horizon.dev/watchdog-armed"
readonly WATCHDOG_UNIT="horizon-watchdog"
readonly WATCHDOG_TOKEN_PATH="/etc/horizon/token"
readonly INJECTION_JOB_IMAGE="docker.io/library/debian:bookworm-slim"
readonly PROM_NAMESPACE="monitoring"
readonly PROM_SERVICE="kube-prometheus-stack-prometheus"
readonly PROM_LOCAL_PORT=19090
readonly HETZNER_PRICING_URL="https://api.hetzner.cloud/v1/pricing"

usage() {
  cat <<'USAGE'
Usage: measure-burst.sh --scenario SCENARIO [options]

Applies a CapacityLease, polls the Hetzner API, the lease status and the
burst Node every 5 seconds, performs a scripted failure injection at a fixed
offset after Ready, and exports per-run artefacts. Every real run bills at
least one Hetzner instance-hour; the script never retries a boot
automatically.

Required (unless --dry-run, which fills in defaults):
  --region REGION             Hetzner region, e.g. hel1
  --size SIZE                 Hetzner server type, e.g. cx23
  --duration DURATION         CapacityLease duration, e.g. 10m (5m..8h)

Always required:
  --scenario SCENARIO         none|control-plane|agent|both|node-token

Options:
  --name NAME                 lease name (default: measure-<timestamp>-<scenario>)
  --replicas N                default 1
  --provider-ref NAME         default hetzner
  --teardown-grace DURATION   default 2m
  --injection-offset SECONDS  seconds after the node is ready to inject (default 30)
  --out-dir DIR                artefact root (default <repo>/var/measure-burst-runs)
  --max-wait SECONDS           override the safety timeout on the poll loop
  --dry-run                    exercise polling and export without creating a server
  -h, --help                   show this help
USAGE
}

name=""
region=""
size=""
duration=""
replicas="$DEFAULT_REPLICAS"
scenario=""
provider_ref="$DEFAULT_PROVIDER_REF"
teardown_grace="$DEFAULT_TEARDOWN_GRACE"
injection_offset_s="$DEFAULT_INJECTION_OFFSET_S"
out_dir="$DEFAULT_OUT_DIR"
max_wait_override=""
dry_run=0

die() {
  echo "measure-burst: $1" >&2
  exit 1
}

require_value() {
  local flag="$1"
  shift
  if [ "$#" -eq 0 ] || [ -z "$1" ]; then
    die "${flag} requires a value"
  fi
  case "$1" in
  --*) die "${flag} requires a value, got the flag '$1'" ;;
  esac
}

require_pattern() {
  local flag="$1" value="$2" pattern="$3" expectation="$4"
  if ! [[ "$value" =~ $pattern ]]; then
    die "${flag} must be ${expectation}, got '${value}'"
  fi
}

parse_duration_to_seconds() {
  local original="$1" remaining="$1" total=0 num unit
  while [[ "$remaining" =~ ^([0-9]+)(h|m|s)(.*)$ ]]; do
    num="${BASH_REMATCH[1]}"
    unit="${BASH_REMATCH[2]}"
    remaining="${BASH_REMATCH[3]}"
    case "$unit" in
    h) total=$((total + num * 3600)) ;;
    m) total=$((total + num * 60)) ;;
    s) total=$((total + num)) ;;
    esac
  done
  if [ -n "$remaining" ] || [ "$total" -eq 0 ]; then
    echo "measure-burst: cannot parse duration '${original}', expected whole hour, minute and second parts such as 10m or 1h30m" >&2
    return 1
  fi
  echo "$total"
}

while [ $# -gt 0 ]; do
  case "$1" in
  --name) require_value "$@"; name="$2"; shift 2 ;;
  --region) require_value "$@"; region="$2"; shift 2 ;;
  --size) require_value "$@"; size="$2"; shift 2 ;;
  --duration) require_value "$@"; duration="$2"; shift 2 ;;
  --replicas) require_value "$@"; replicas="$2"; shift 2 ;;
  --scenario) require_value "$@"; scenario="$2"; shift 2 ;;
  --provider-ref) require_value "$@"; provider_ref="$2"; shift 2 ;;
  --teardown-grace) require_value "$@"; teardown_grace="$2"; shift 2 ;;
  --injection-offset) require_value "$@"; injection_offset_s="$2"; shift 2 ;;
  --out-dir) require_value "$@"; out_dir="$2"; shift 2 ;;
  --max-wait) require_value "$@"; max_wait_override="$2"; shift 2 ;;
  --dry-run) dry_run=1; shift ;;
  -h | --help) usage; exit 0 ;;
  *)
    echo "measure-burst: unknown argument: $1" >&2
    usage >&2
    exit 1
    ;;
  esac
done

case "$scenario" in
none | control-plane | agent | both | node-token) ;;
"") die "--scenario is required" ;;
*) die "unknown scenario '${scenario}', must be one of: none control-plane agent both node-token" ;;
esac

if [ "$dry_run" -eq 1 ]; then
  region="${region:-hel1}"
  size="${size:-cx23}"
  duration="${duration:-10m}"
elif [ -z "$region" ] || [ -z "$size" ] || [ -z "$duration" ]; then
  die "--region, --size and --duration are required outside --dry-run"
fi

if [ -z "$name" ]; then
  name="measure-$(date +%Y%m%d%H%M%S)-${scenario}"
fi

readonly DNS_LABEL_PATTERN='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
readonly POSITIVE_INTEGER_PATTERN='^[1-9][0-9]*$'
readonly NON_NEGATIVE_INTEGER_PATTERN='^(0|[1-9][0-9]*)$'

require_pattern --name "$name" "$DNS_LABEL_PATTERN" "a lowercase alphanumeric DNS label"
if [ "${#name}" -gt "$MAX_LEASE_NAME_LENGTH" ]; then
  die "--name must be at most ${MAX_LEASE_NAME_LENGTH} characters so derived Job names stay valid, got ${#name}"
fi
require_pattern --region "$region" "$DNS_LABEL_PATTERN" "a lowercase alphanumeric Hetzner region such as hel1"
require_pattern --size "$size" "$DNS_LABEL_PATTERN" "a lowercase alphanumeric Hetzner server type such as cx23"
require_pattern --provider-ref "$provider_ref" "$DNS_LABEL_PATTERN" "a lowercase alphanumeric object name"
require_pattern --replicas "$replicas" "$POSITIVE_INTEGER_PATTERN" "a positive whole number"
require_pattern --injection-offset "$injection_offset_s" "$NON_NEGATIVE_INTEGER_PATTERN" "a whole number of seconds"
if [ -n "$max_wait_override" ]; then
  require_pattern --max-wait "$max_wait_override" "$POSITIVE_INTEGER_PATTERN" "a positive whole number of seconds"
fi

duration_s=$(parse_duration_to_seconds "$duration") || die "--duration is not a duration this harness can measure"
parse_duration_to_seconds "$teardown_grace" >/dev/null || die "--teardown-grace is not a duration this harness can measure"

for tool in kubectl hcloud jq curl; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    die "$tool is not on PATH; run this script inside 'nix develop', which provides it"
  fi
done

if ! date -u -d "@0" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
  die "GNU date is required; run this script inside 'nix develop', which provides coreutils"
fi

hcloud_token="$(kubectl get secret "$HETZNER_SECRET_NAME" -n "$HETZNER_SECRET_NAMESPACE" -o jsonpath='{.data.token}' | base64 -d)"
if [ -z "$hcloud_token" ]; then
  echo "measure-burst: empty Hetzner token from secret ${HETZNER_SECRET_NAMESPACE}/${HETZNER_SECRET_NAME}" >&2
  exit 1
fi
export HCLOUD_TOKEN="$hcloud_token"

run_dir="${out_dir}/${name}"
mkdir -p "$run_dir"
csv_path="${run_dir}/harness.csv"
lease_json_path="${run_dir}/lease-final.json"
operator_log_path="${run_dir}/operator.log"
prom_dir="${run_dir}/prometheus"
hetzner_pricing_path="${run_dir}/hetzner-pricing.json"
injection_log_path="${run_dir}/injection.log"
run_params_path="${run_dir}/run-params.json"

lease_applied=0
lease_dumped=0
operator_scaled_down=0
original_operator_replicas=""
injected=0
server_ever_seen=0
hetzner_poll_failures=0
start_epoch=0
start_iso=""
operator_log_captured_until=""
ready_epoch=""
ready_source=""
node_names=()
declare -A hetzner_seen
declare -A lease_seen
declare -A node_seen

write_csv_row() {
  printf '%s,%s,%s,%s,%s,%s\n' "$1" "$2" "$3" "$4" "$5" "$6" >>"$csv_path"
}

emit_event() {
  local now_epoch now_iso elapsed
  now_epoch=$(date +%s)
  now_iso=$(date -u -d "@${now_epoch}" +%Y-%m-%dT%H:%M:%SZ)
  elapsed=$((now_epoch - start_epoch))
  write_csv_row "$now_iso" "$elapsed" "$1" "$2" "$3" "$4"
}

emit_event_at() {
  local elapsed="$5" iso
  iso=$(date -u -d "@$((start_epoch + elapsed))" +%Y-%m-%dT%H:%M:%SZ)
  write_csv_row "$iso" "$elapsed" "$1" "$2" "$3" "$4"
}

csv_header() {
  echo "timestamp,elapsed_s,source,object,field,value" >"$csv_path"
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
  size: ${size}
  replicas: ${replicas}
  duration: ${duration}
  teardownGrace: ${teardown_grace}
YAML
}

build_injection_job_manifest() {
  local job="$1" node="$2" host_cmd="$3" indented_host_cmd
  indented_host_cmd=$(printf '%s\n' "$host_cmd" | sed 's/^/              /')
  cat <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: ${job}
  namespace: ${INJECTION_NAMESPACE}
  labels:
    ${LEASE_LABEL_KEY}: ${name}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 300
  template:
    metadata:
      labels:
        ${LEASE_LABEL_KEY}: ${name}
    spec:
      restartPolicy: Never
      hostPID: true
      nodeSelector:
        kubernetes.io/hostname: ${node}
      tolerations:
        - key: ${BURST_TAINT_KEY}
          operator: Exists
          effect: NoSchedule
      containers:
        - name: inject
          image: ${INJECTION_JOB_IMAGE}
          securityContext:
            privileged: true
          command:
            - nsenter
            - --target
            - "1"
            - --mount
            - --uts
            - --ipc
            - --net
            - --pid
            - --
            - sh
            - -c
            - |
${indented_host_cmd}
YAML
}

apply_lease() {
  build_lease_manifest | kubectl apply -f -
  lease_applied=1
}

hetzner_active_count() {
  local n=0 k
  for k in "${!hetzner_seen[@]}"; do
    [ "${hetzner_seen[$k]}" != "absent" ] && n=$((n + 1))
  done
  echo "$n"
}

# A failed query must never leave the seen map looking like an empty estate, because that reads as a teardown the harness would then report as measured.
poll_hetzner() {
  local json count sname sstatus found s
  if ! json=$(hcloud server list -l "${LEASE_LABEL_KEY}=${name}" -o json 2>/dev/null) ||
    ! count=$(printf '%s' "$json" | jq 'length' 2>/dev/null) || [ -z "$count" ]; then
    hetzner_poll_failures=$((hetzner_poll_failures + 1))
    emit_event hetzner "$name" poll-failed "$hetzner_poll_failures"
    if [ "$hetzner_poll_failures" -ge "$HETZNER_POLL_FAILURE_LIMIT" ]; then
      echo "measure-burst: FATAL the Hetzner API failed ${hetzner_poll_failures} times in a row and it is the only authority on whether a server still bills" >&2
      exit 1
    fi
    echo "measure-burst: WARNING Hetzner API query failed (${hetzner_poll_failures} in a row)" >&2
    return 1
  fi
  hetzner_poll_failures=0
  [ "$count" -gt 0 ] && server_ever_seen=1

  local seen_names=()
  while IFS=$'\t' read -r sname sstatus; do
    [ -n "$sname" ] || continue
    seen_names+=("$sname")
    if [ "${hetzner_seen[$sname]:-}" != "$sstatus" ]; then
      emit_event hetzner "$sname" status "$sstatus"
      hetzner_seen[$sname]="$sstatus"
    fi
  done < <(printf '%s' "$json" | jq -r '.[] | [.name, .status] | @tsv')

  for s in "${!hetzner_seen[@]}"; do
    found=0
    for sname in "${seen_names[@]:-}"; do
      [ "$sname" = "$s" ] && found=1 && break
    done
    if [ "$found" -eq 0 ] && [ "${hetzner_seen[$s]}" != "absent" ]; then
      emit_event hetzner "$s" status absent
      hetzner_seen[$s]="absent"
    fi
  done
}

record_ready_instant() {
  local epoch="$1" source="$2"
  [ "$ready_source" = lease-readyAt ] && return 0
  ready_epoch="$epoch"
  ready_source="$source"
  emit_event harness "$name" ready-instant "$(date -u -d "@${epoch}" +%Y-%m-%dT%H:%M:%SZ) via ${source}"
}

poll_lease() {
  local json field value node known n readyat_epoch
  json=$(kubectl get capacitylease "$name" -o json 2>/dev/null) || return 0
  for field in phase acceptedAt readyAt expiresAt releasedAt instanceType; do
    value=$(printf '%s' "$json" | jq -r --arg f "$field" '.status[$f] // empty')
    if [ -n "$value" ] && [ "${lease_seen[$field]:-}" != "$value" ]; then
      emit_event lease "$name" "$field" "$value"
      lease_seen[$field]="$value"
      if [ "$field" = readyAt ] && readyat_epoch=$(date -u -d "$value" +%s 2>/dev/null); then
        record_ready_instant "$readyat_epoch" lease-readyAt
      fi
    fi
  done

  while IFS= read -r node; do
    [ -n "$node" ] || continue
    known=0
    for n in "${node_names[@]:-}"; do
      [ "$n" = "$node" ] && known=1 && break
    done
    if [ "$known" -eq 0 ]; then
      node_names+=("$node")
      emit_event lease "$name" nodeName "$node"
    fi
  done < <(printf '%s' "$json" | jq -r '.status.instances[]?.nodeName // empty')
}

poll_node() {
  local node json ready armed
  for node in "${node_names[@]:-}"; do
    json=$(kubectl get node "$node" -o json 2>/dev/null) || continue
    ready=$(printf '%s' "$json" | jq -r '.status.conditions[]? | select(.type=="Ready") | .status')
    armed=$(printf '%s' "$json" | jq -r --arg k "$WATCHDOG_ARMED_ANNOTATION" '.metadata.annotations[$k] // empty')
    if [ -n "$ready" ] && [ "${node_seen[$node,ready]:-}" != "$ready" ]; then
      emit_event node "$node" ready "$ready"
      node_seen[$node,ready]="$ready"
      if [ "$ready" = True ] && [ -z "$ready_epoch" ]; then
        record_ready_instant "$(date +%s)" node-ready-transition
      fi
    fi
    if [ -n "$armed" ] && [ "${node_seen[$node,armed]:-}" != "$armed" ]; then
      emit_event node "$node" watchdog-armed "$armed"
      node_seen[$node,armed]="$armed"
    fi
  done
}

capture_operator_log_so_far() {
  local until
  until=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  kubectl -n "$OPERATOR_NAMESPACE" logs "deploy/${OPERATOR_DEPLOYMENT}" --since-time="$operator_log_captured_until" >>"$operator_log_path" 2>/dev/null || true
  operator_log_captured_until="$until"
}

await_job_outcome() {
  local job="$1" deadline="$2" json condition
  while :; do
    if json=$(kubectl -n "$INJECTION_NAMESPACE" get job "$job" -o json 2>/dev/null); then
      condition=$(printf '%s' "$json" | jq -r '[.status.conditions[]? | select(.status=="True") | select(.type=="Complete" or .type=="Failed") | .type][0] // empty')
      case "$condition" in
      Complete)
        echo succeeded
        return 0
        ;;
      Failed)
        echo failed
        return 0
        ;;
      esac
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo mechanism-timeout
      return 0
    fi
    sleep "$POLL_INTERVAL_S"
  done
}

run_injection_job() {
  local node="$1" suffix="$2" host_cmd="$3" job outcome
  job="${name}-inject-${suffix}"
  build_injection_job_manifest "$job" "$node" "$host_cmd" | kubectl apply -f - >/dev/null
  outcome=$(await_job_outcome "$job" "$(($(date +%s) + INJECTION_JOB_MAX_WAIT_S))")
  {
    echo "=== ${job} (${outcome}) ==="
    kubectl -n "$INJECTION_NAMESPACE" logs "job/${job}" --tail=50 2>&1
  } >>"$injection_log_path"
  case "$outcome" in
  failed)
    echo "measure-burst: WARNING injection job ${job} ran and failed; see ${injection_log_path}" >&2
    kubectl -n "$INJECTION_NAMESPACE" delete job "$job" --ignore-not-found --wait=false >/dev/null
    ;;
  mechanism-timeout)
    echo "measure-burst: WARNING injection job ${job} did not reach a terminal condition within ${INJECTION_JOB_MAX_WAIT_S}s" >&2
    echo "measure-burst: WARNING the injection mechanism, not the system under test, is unmeasured for this run" >&2
    echo "measure-burst: leaving ${INJECTION_NAMESPACE}/${job} in place for inspection; delete it by hand once read" >&2
    echo "=== ${job} retained for inspection, no terminal condition ===" >>"$injection_log_path"
    ;;
  *)
    kubectl -n "$INJECTION_NAMESPACE" delete job "$job" --ignore-not-found --wait=false >/dev/null
    ;;
  esac
  echo "$outcome"
}

inject_control_plane() {
  capture_operator_log_so_far
  original_operator_replicas=$(kubectl -n "$OPERATOR_NAMESPACE" get deploy "$OPERATOR_DEPLOYMENT" -o jsonpath='{.spec.replicas}')
  if ! [[ "$original_operator_replicas" =~ $POSITIVE_INTEGER_PATTERN ]]; then
    die "cannot read the replica count of ${OPERATOR_NAMESPACE}/${OPERATOR_DEPLOYMENT}, got '${original_operator_replicas}'; refusing to scale it to zero with no way back"
  fi
  kubectl -n "$OPERATOR_NAMESPACE" scale "deploy/${OPERATOR_DEPLOYMENT}" --replicas=0
  operator_scaled_down=1
  emit_event injection operator scaled-to-zero "$original_operator_replicas"
}

restore_operator() {
  [ "$operator_scaled_down" -eq 1 ] || return 0
  local observed
  kubectl -n "$OPERATOR_NAMESPACE" scale "deploy/${OPERATOR_DEPLOYMENT}" --replicas="$original_operator_replicas" >/dev/null 2>&1
  observed=$(kubectl -n "$OPERATOR_NAMESPACE" get deploy "$OPERATOR_DEPLOYMENT" -o jsonpath='{.spec.replicas}' 2>/dev/null) || observed=""
  if [ "$observed" != "$original_operator_replicas" ]; then
    echo "measure-burst: FATAL ${OPERATOR_NAMESPACE}/${OPERATOR_DEPLOYMENT} reads '${observed}' replicas, not the recorded ${original_operator_replicas}" >&2
    echo "measure-burst: restore it by hand now: kubectl -n ${OPERATOR_NAMESPACE} scale deploy/${OPERATOR_DEPLOYMENT} --replicas=${original_operator_replicas}" >&2
    return 1
  fi
  operator_scaled_down=0
  echo "measure-burst: operator restored to ${original_operator_replicas} replicas and verified" >&2
  emit_event harness operator restored "$original_operator_replicas"
}

inject_agent() {
  local node outcome host_cmd
  host_cmd=$(cat <<SH
systemctl stop ${WATCHDOG_UNIT}
if systemctl is-active --quiet ${WATCHDOG_UNIT}; then
  echo "${WATCHDOG_UNIT} is still active after stop"
  exit 1
fi
echo "${WATCHDOG_UNIT} stopped"
SH
  )
  for node in "${node_names[@]:-}"; do
    outcome=$(run_injection_job "$node" agent "$host_cmd")
    emit_event injection "$node" watchdog-stop "$outcome"
  done
}

# The agent reads its token once at process start and builds its API client from that copy, so revoking the file alone leaves the running process authenticated.
inject_node_token() {
  local node outcome host_cmd
  host_cmd=$(cat <<SH
before=\$(systemctl show -p InvocationID --value ${WATCHDOG_UNIT})
printf revoked > ${WATCHDOG_TOKEN_PATH}
systemctl restart ${WATCHDOG_UNIT}
after=\$(systemctl show -p InvocationID --value ${WATCHDOG_UNIT})
if [ -z "\$after" ] || [ "\$after" = "\$before" ]; then
  echo "${WATCHDOG_UNIT} did not restart, the running agent still holds the old token"
  exit 1
fi
echo "${WATCHDOG_UNIT} restarted, invocation \$before to \$after"
SH
  )
  for node in "${node_names[@]:-}"; do
    outcome=$(run_injection_job "$node" token "$host_cmd")
    emit_event injection "$node" token-revoke "$outcome"
  done
}

perform_injection() {
  echo "measure-burst: performing injection scenario=${scenario} at $(($(date +%s) - start_epoch))s" >&2
  case "$scenario" in
  control-plane) inject_control_plane ;;
  agent) inject_agent ;;
  both)
    inject_control_plane
    inject_agent
    ;;
  node-token) inject_node_token ;;
  esac
}

maybe_inject() {
  [ "$scenario" = none ] && return 0
  [ "$injected" -eq 1 ] && return 0
  local now_epoch
  now_epoch=$(date +%s)
  if [ -z "$ready_epoch" ]; then
    if [ $((now_epoch - start_epoch)) -ge "$READINESS_SIGNAL_MAX_WAIT_S" ]; then
      echo "measure-burst: FATAL neither .status.readyAt nor a node Ready=True transition appeared within ${READINESS_SIGNAL_MAX_WAIT_S}s" >&2
      echo "measure-burst: scenario=${scenario} has no instant to inject against, so the run would measure nothing; aborting into cleanup" >&2
      exit 1
    fi
    return 0
  fi
  [ "${#node_names[@]}" -eq 0 ] && return 0
  if [ $((now_epoch - ready_epoch)) -ge "$injection_offset_s" ]; then
    perform_injection
    injected=1
  fi
}

export_prometheus() {
  mkdir -p "$prom_dir"
  local pf_pid ready attempts_left series name_i end_epoch
  kubectl -n "$PROM_NAMESPACE" port-forward "svc/${PROM_SERVICE}" "${PROM_LOCAL_PORT}:9090" >/dev/null 2>&1 &
  pf_pid=$!
  ready=0
  attempts_left=20
  while [ "$attempts_left" -gt 0 ]; do
    if curl -sf "http://127.0.0.1:${PROM_LOCAL_PORT}/-/ready" >/dev/null 2>&1; then
      ready=1
      break
    fi
    attempts_left=$((attempts_left - 1))
    sleep 0.5
  done
  if [ "$ready" -ne 1 ]; then
    echo "measure-burst: WARNING prometheus port-forward not ready, skipping range-query export" >&2
    emit_event harness "$name" export-prometheus port-forward-unavailable
    kill "$pf_pid" 2>/dev/null || true
    wait "$pf_pid" 2>/dev/null || true
    return 0
  fi

  end_epoch=$(date +%s)
  series=$(curl -sf --get "http://127.0.0.1:${PROM_LOCAL_PORT}/api/v1/label/__name__/values" \
    --data-urlencode 'match[]={__name__=~"^horizon_"}' 2>/dev/null | jq -r '.data[]?' 2>/dev/null) || series=""
  if [ -z "$series" ]; then
    echo "measure-burst: no horizon_ series in Prometheus for this window" >&2
  fi
  local exported=0 failed=0
  for name_i in $series; do
    if curl -sf --get "http://127.0.0.1:${PROM_LOCAL_PORT}/api/v1/query_range" \
      --data-urlencode "query=${name_i}" \
      --data-urlencode "start=${start_epoch}" \
      --data-urlencode "end=${end_epoch}" \
      --data-urlencode "step=15s" \
      -o "${prom_dir}/${name_i}.json"; then
      exported=$((exported + 1))
    else
      failed=$((failed + 1))
      rm -f "${prom_dir}/${name_i}.json"
      echo "measure-burst: WARNING range query failed for ${name_i}" >&2
    fi
  done
  emit_event harness "$name" export-prometheus "${exported}-series-${failed}-failed"

  kill "$pf_pid" 2>/dev/null || true
  wait "$pf_pid" 2>/dev/null || true
}

export_hetzner_pricing() {
  if curl -sf -H "Authorization: Bearer ${HCLOUD_TOKEN}" "$HETZNER_PRICING_URL" -o "$hetzner_pricing_path"; then
    echo "measure-burst: wrote current Hetzner pricing to ${hetzner_pricing_path} (rates at export time, not a historical invoice: the Cloud API exposes no per-resource usage/invoice endpoint reachable with a project token)" >&2
    emit_event harness "$name" export-pricing ok
  else
    echo "measure-burst: WARNING Hetzner pricing endpoint unreachable, skipping" >&2
    emit_event harness "$name" export-pricing failed
  fi
}

write_run_params() {
  local dry_run_json="false"
  [ "$dry_run" -eq 1 ] && dry_run_json="true"
  cat >"$run_params_path" <<JSON
{
  "name": "${name}",
  "scenario": "${scenario}",
  "size": "${size}",
  "region": "${region}",
  "duration": "${duration}",
  "replicas": ${replicas},
  "teardownGrace": "${teardown_grace}",
  "injectionOffsetSeconds": ${injection_offset_s},
  "startedAt": "${start_iso}",
  "dryRun": ${dry_run_json}
}
JSON
}

run_export() {
  local label="$1"
  shift
  if "$@"; then
    return 0
  fi
  echo "measure-burst: WARNING the ${label} export failed; the remaining exports still run" >&2
  emit_event harness "$name" export-failed "$label" || true
}

export_artifacts() {
  echo "measure-burst: exporting artefacts to ${run_dir}" >&2
  if kubectl get capacitylease "$name" -o json >"$lease_json_path" 2>/dev/null; then
    lease_dumped=1
  else
    echo '{"note":"lease no longer exists at export time"}' >"$lease_json_path"
  fi
  run_export operator-log capture_operator_log_so_far
  run_export prometheus export_prometheus
  run_export hetzner-pricing export_hetzner_pricing
  run_export run-params write_run_params
}

count_lease_servers() {
  local listing count
  listing=$(hcloud server list -l "${LEASE_LABEL_KEY}=${name}" -o json 2>/dev/null) || return 1
  count=$(printf '%s' "$listing" | jq 'length' 2>/dev/null) || return 1
  case "$count" in
  '' | *[!0-9]*) return 1 ;;
  esac
  echo "$count"
}

force_delete_lease_servers() {
  local ids id
  ids=$(hcloud server list -l "${LEASE_LABEL_KEY}=${name}" -o json 2>/dev/null | jq -r '.[].id' 2>/dev/null) || ids=""
  if [ -z "$ids" ]; then
    echo "measure-burst: FATAL could not list servers to force-delete; delete them by hand now" >&2
    return 1
  fi
  for id in $ids; do
    hcloud server delete "$id" || echo "measure-burst: FATAL forced delete of server ${id} failed, delete it by hand now" >&2
  done
}

# Cleanup is the only guarantee that a billed server is gone, so it disables errexit and ignores interrupts to make sure no single failure can skip the paths below.
cleanup() {
  local exit_code=$?
  trap - EXIT
  trap '' INT TERM
  set +e
  echo "measure-burst: cleanup: verifying no server remains for lease ${name}" >&2

  restore_operator || exit_code=1

  if [ "$lease_dumped" -eq 0 ] && [ "$lease_applied" -eq 1 ]; then
    kubectl get capacitylease "$name" -o json >"$lease_json_path" 2>/dev/null
  fi

  if [ "$lease_applied" -eq 1 ] && [ "$dry_run" -eq 0 ]; then
    kubectl delete capacitylease "$name" --ignore-not-found --wait=false >/dev/null 2>&1
  fi

  local remaining="$((CLEANUP_MAX_WAIT_S / CLEANUP_POLL_INTERVAL_S))" count="unknown"
  while [ "$remaining" -gt 0 ]; do
    count=$(count_lease_servers) || count="unknown"
    if [ "$count" = 0 ]; then
      emit_event harness "$name" cleanup-verified zero-servers
      break
    fi
    if [ "$count" = unknown ]; then
      emit_event harness "$name" cleanup-poll hetzner-query-failed
    else
      emit_event harness "$name" cleanup-poll "${count}-servers-remain"
    fi
    remaining=$((remaining - 1))
    sleep "$CLEANUP_POLL_INTERVAL_S"
  done

  if [ "$count" = 0 ]; then
    echo "measure-burst: verified zero servers for lease ${name}" >&2
  else
    if [ "$count" = unknown ]; then
      echo "measure-burst: FATAL could not determine how many servers exist for lease ${name} after ${CLEANUP_MAX_WAIT_S}s" >&2
    else
      echo "measure-burst: FATAL ${count} server(s) still exist for lease ${name} after ${CLEANUP_MAX_WAIT_S}s" >&2
    fi
    echo "measure-burst: inspect with: hcloud server list -l ${LEASE_LABEL_KEY}=${name}" >&2
    if [ "$dry_run" -eq 0 ]; then
      echo "measure-burst: forcing hcloud delete as last resort" >&2
      force_delete_lease_servers
    fi
    exit_code=1
  fi

  exit "$exit_code"
}
trap cleanup EXIT INT TERM

preflight_node_access() {
  case "$scenario" in
  agent | both | node-token) ;;
  *) return 0 ;;
  esac
  echo "measure-burst: scenario=${scenario} needs on-node access via a privileged hostPID Job (burst nodes carry no SSH key); probing admission control before spending a boot" >&2
  local probe result
  probe=$(build_injection_job_manifest "${name}-inject-probe" "preflight-probe-node" "true")
  if ! result=$(printf '%s' "$probe" | kubectl apply --dry-run=server -f - 2>&1); then
    echo "measure-burst: UNSUPPORTED, scenario=${scenario} cannot run in this estate right now" >&2
    echo "measure-burst: admission control rejected the injection Job in namespace ${INJECTION_NAMESPACE}:" >&2
    # shellcheck disable=SC2001
    echo "$result" | sed 's/^/  /' >&2
    echo "measure-burst: no lease was applied and nothing was billed" >&2
    echo "measure-burst: scenario=${scenario} needs a namespace that admits a privileged hostPID pod; either relax admission for ${INJECTION_NAMESPACE} or run scenario=none or control-plane, which need no on-node access" >&2
    exit 1
  fi
  echo "measure-burst: node-access probe accepted, proceeding" >&2
}

observe_until() {
  local deadline="$1"
  local hetzner_fresh
  while :; do
    hetzner_fresh=0
    poll_hetzner && hetzner_fresh=1
    poll_lease
    poll_node
    maybe_inject

    if [ "$hetzner_fresh" -eq 1 ] && [ "$server_ever_seen" -eq 1 ] && [ "$(hetzner_active_count)" -eq 0 ]; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    sleep "$POLL_INTERVAL_S"
  done
}

real_run() {
  start_epoch=$(date +%s)
  start_iso=$(date -u -d "@${start_epoch}" +%Y-%m-%dT%H:%M:%SZ)
  operator_log_captured_until="$start_iso"
  csv_header

  preflight_node_access

  echo "measure-burst: applying lease ${name} (scenario=${scenario}, size=${size}, region=${region}, duration=${duration}, replicas=${replicas})" >&2
  apply_lease
  emit_event harness "$name" lease-applied "$scenario"

  local max_wait
  max_wait="${max_wait_override:-$((duration_s + BOOT_BUFFER_S + TEARDOWN_BUFFER_S + WATCHDOG_WALLCLOCK_BUFFER_S))}"

  if observe_until "$((start_epoch + max_wait))"; then
    echo "measure-burst: hetzner reports zero servers for ${name}; teardown observed at $(($(date +%s) - start_epoch))s" >&2
  elif [ "$operator_scaled_down" -eq 1 ]; then
    echo "measure-burst: reached ${max_wait}s with no teardown while the operator is scaled to zero, which is the expected result for scenario=${scenario}" >&2
  else
    echo "measure-burst: WARNING reached ${max_wait}s with no confirmed teardown; investigate before assuming a leak" >&2
  fi

  if [ "$operator_scaled_down" -eq 1 ]; then
    echo "measure-burst: restoring the operator and observing collection for up to ${OPERATOR_RESTORE_SETTLE_S}s so the artefacts cover the window" >&2
    restore_operator || true
    if observe_until "$(($(date +%s) + OPERATOR_RESTORE_SETTLE_S))"; then
      echo "measure-burst: teardown observed after the operator returned, at $(($(date +%s) - start_epoch))s" >&2
    else
      echo "measure-burst: WARNING no teardown within ${OPERATOR_RESTORE_SETTLE_S}s of the operator returning" >&2
    fi
  fi

  export_artifacts
}

replay_synthetic_timeline() {
  local server="${name}-0" node="${name}-node-0"
  emit_event_at hetzner "$server" status initializing 4
  emit_event_at hetzner "$server" status starting 10
  emit_event_at lease "$name" phase Pending 0
  emit_event_at lease "$name" acceptedAt "$(date -u -d "@$((start_epoch + 1))" +%Y-%m-%dT%H:%M:%SZ)" 1
  emit_event_at lease "$name" phase Provisioning 2
  emit_event_at hetzner "$server" status running 18
  emit_event_at lease "$name" nodeName "$node" 60
  emit_event_at node "$node" ready False 65
  emit_event_at node "$node" ready True 72
  emit_event_at node "$node" watchdog-armed true 75
  emit_event_at lease "$name" readyAt "$(date -u -d "@$((start_epoch + 72))" +%Y-%m-%dT%H:%M:%SZ)" 72
  emit_event_at lease "$name" phase Active 72
  emit_event_at injection "$name" scenario-simulated "$scenario" $((72 + injection_offset_s))
  emit_event_at lease "$name" expiresAt "$(date -u -d "@$((start_epoch + 600))" +%Y-%m-%dT%H:%M:%SZ)" 600
  emit_event_at hetzner "$server" status deleting 615
  emit_event_at hetzner "$server" status absent 622
  emit_event_at lease "$name" releasedAt "$(date -u -d "@$((start_epoch + 622))" +%Y-%m-%dT%H:%M:%SZ)" 622
  emit_event_at lease "$name" phase Released 622
}

dry_run_flow() {
  start_epoch=$(date +%s)
  start_iso=$(date -u -d "@${start_epoch}" +%Y-%m-%dT%H:%M:%SZ)
  csv_header

  echo "measure-burst: dry-run, validating lease manifest against the live API server (server-side dry-run, nothing persisted)" >&2
  build_lease_manifest | kubectl apply --dry-run=server -f -

  preflight_node_access

  echo "measure-burst: dry-run, replaying a synthetic event timeline through the real CSV writer" >&2
  replay_synthetic_timeline

  echo "{\"status\":{\"phase\":\"Released\",\"acceptedAt\":\"${start_iso}\",\"note\":\"synthetic dry-run lease, never applied to the cluster\"}}" >"$lease_json_path"
  lease_dumped=1

  export_prometheus
  export_hetzner_pricing
  write_run_params
}

if [ "$dry_run" -eq 1 ]; then
  dry_run_flow
else
  real_run
fi

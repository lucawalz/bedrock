#!/usr/bin/env bash
set -euo pipefail

readonly PROGRAM_NAME="run-quantum"

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/measure.sh
. "${repo_root}/scripts/lib/measure.sh"
cd "$repo_root"

readonly QUANTUM_SOURCE="${repo_root}/scripts/quantum.py"
readonly QUANTUM_IMAGE="docker.io/library/python:3.13-alpine3.21@sha256:71397d15c4c450526972669d41cad5bf89fd463c0027cc93af15891215f6c56b"

readonly DEFAULT_NAMESPACE="monitoring"
readonly DEFAULT_REPLICAS=1
readonly DEFAULT_OUT_DIR="${repo_root}/var/quantum-runs"
readonly DEFAULT_MAX_WAIT_S=1800

readonly POOL_LABEL_KEY="horizon.dev/pool"
readonly POOL_LABEL_VALUE="reserved"
readonly QUANTUM_LABEL_KEY="horizon.dev/quantum"
readonly HOSTNAME_LABEL_KEY="kubernetes.io/hostname"

readonly PROGRAM_MOUNT_PATH="/opt/quantum"
readonly BACKOFF_LIMIT=2
readonly JOB_TTL_S=3600
readonly MAX_NAME_LENGTH=52
readonly CPU_REQUEST="500m"
readonly MEMORY_REQUEST="64Mi"
readonly MEMORY_LIMIT="256Mi"
readonly UNPRIVILEGED_UID=65534

usage() {
  cat <<'USAGE'
Usage: run-quantum.sh [options]

Runs the fixed synthetic quantum as a Kubernetes Job, one unit of work per
burst node, and collects the per-node result lines the containers emit. The
quantum is a fixed quantity of computation, so its wall-clock time varies with
the machine; that elapsed figure is measured inside the container and excludes
scheduling and image pull.

The calibrated work parameter lives in scripts/quantum.py as
DEFAULT_SHARD_ITERATIONS. Retuning after the first real boot is a change to
that one number, or a --shard-iterations override for a single run.

Options:
  --name NAME               job and ConfigMap name (default: quantum-<timestamp>)
  --namespace NAMESPACE     default monitoring
  --replicas N              units of work, one per node (default 1)
  --nodes NAME[,NAME...]    pin the units to these node names instead of the pool label
  --shard-iterations N      override the calibrated work parameter
  --seed N                  override the fixed input
  --workers N               cap the worker processes, for calibration only
  --expect-checksum HEX     fail unless every unit reports this checksum
  --out-dir DIR             artefact root (default <repo>/var/quantum-runs)
  --max-wait SECONDS        give up waiting for completion (default 1800)
  --relax-targeting         drop the burst nodeSelector and toleration
  --render                  print the manifest and exit, touching no cluster
  --keep                    leave the Job and ConfigMap in place
  -h, --help                show this help

--relax-targeting exists so the quantum can be validated on nodes that carry no
burst label. A measurement run never uses it: without the selector the Job can
land on a permanent node and measure the wrong machine. --workers exists for
the same reason, to measure per-core throughput without occupying a whole node;
a measurement run leaves it unset so the quantum uses every core it is given.

--nodes exists because the pool label is shared by every burst node in the
estate. Two leases running side by side both carry it, so a campaign that runs
several leases at once must name the nodes of its own lease or risk measuring
another lease's machine.
USAGE
}

name=""
namespace="$DEFAULT_NAMESPACE"
replicas="$DEFAULT_REPLICAS"
nodes=""
shard_iterations=""
seed=""
workers=""
expect_checksum=""
out_dir="$DEFAULT_OUT_DIR"
max_wait_s="$DEFAULT_MAX_WAIT_S"
relax_targeting=0
render_only=0
keep=0

while [ $# -gt 0 ]; do
  case "$1" in
  --name) require_value "$@"; name="$2"; shift 2 ;;
  --namespace) require_value "$@"; namespace="$2"; shift 2 ;;
  --replicas) require_value "$@"; replicas="$2"; shift 2 ;;
  --nodes) require_value "$@"; nodes="$2"; shift 2 ;;
  --shard-iterations) require_value "$@"; shard_iterations="$2"; shift 2 ;;
  --seed) require_value "$@"; seed="$2"; shift 2 ;;
  --workers) require_value "$@"; workers="$2"; shift 2 ;;
  --expect-checksum) require_value "$@"; expect_checksum="$2"; shift 2 ;;
  --out-dir) require_value "$@"; out_dir="$2"; shift 2 ;;
  --max-wait) require_value "$@"; max_wait_s="$2"; shift 2 ;;
  --relax-targeting) relax_targeting=1; shift ;;
  --render) render_only=1; shift ;;
  --keep) keep=1; shift ;;
  -h | --help) usage; exit 0 ;;
  *)
    echo "run-quantum: unknown argument: $1" >&2
    usage >&2
    exit 1
    ;;
  esac
done

if [ -z "$name" ]; then
  name="quantum-$(date +%Y%m%d%H%M%S)"
fi

require_pattern --name "$name" "$DNS_LABEL_PATTERN" "a lowercase alphanumeric DNS label"
if [ "${#name}" -gt "$MAX_NAME_LENGTH" ]; then
  die "--name must be at most ${MAX_NAME_LENGTH} characters so derived pod names stay valid, got ${#name}"
fi
require_pattern --namespace "$namespace" "$DNS_LABEL_PATTERN" "a lowercase alphanumeric DNS label"
require_pattern --replicas "$replicas" "$POSITIVE_INTEGER_PATTERN" "a positive whole number"
require_pattern --max-wait "$max_wait_s" "$POSITIVE_INTEGER_PATTERN" "a positive whole number of seconds"
if [ -n "$shard_iterations" ]; then
  require_pattern --shard-iterations "$shard_iterations" "$POSITIVE_INTEGER_PATTERN" "a positive whole number"
fi
if [ -n "$seed" ]; then
  require_pattern --seed "$seed" "$POSITIVE_INTEGER_PATTERN" "a positive whole number"
fi
if [ -n "$workers" ]; then
  require_pattern --workers "$workers" "$POSITIVE_INTEGER_PATTERN" "a positive whole number"
fi
if [ -n "$expect_checksum" ]; then
  require_pattern --expect-checksum "$expect_checksum" "$SHA256_HEX_PATTERN" "a lowercase 64-character sha256 digest"
fi

pinned_nodes=()
if [ -n "$nodes" ]; then
  if [ "$relax_targeting" -eq 1 ]; then
    die "--nodes and --relax-targeting contradict each other; pick the pinned nodes or no targeting at all"
  fi
  IFS=',' read -r -a pinned_nodes <<<"$nodes"
  for node in "${pinned_nodes[@]}"; do
    require_pattern "each name in --nodes" "$node" "$DNS_LABEL_PATTERN" \
      "a lowercase alphanumeric DNS label, because it is interpolated into a generated manifest"
  done
  if [ "${#pinned_nodes[@]}" -lt "$replicas" ]; then
    die "--nodes names ${#pinned_nodes[@]} node(s) for ${replicas} unit(s); one unit per node cannot be satisfied"
  fi
fi

[ -r "$QUANTUM_SOURCE" ] || die "cannot read ${QUANTUM_SOURCE}"

render_optional_env() {
  local variable="$1" value="$2"
  [ -n "$value" ] || return 0
  cat <<YAML
            - name: ${variable}
              value: "${value}"
YAML
}

render_node_affinity() {
  [ -n "$nodes" ] || return 0
  local node
  cat <<YAML
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: ${HOSTNAME_LABEL_KEY}
                    operator: In
                    values:
YAML
  for node in "${pinned_nodes[@]}"; do
    echo "                      - ${node}"
  done
}

# The taint value is the lease name, so the toleration matches the key with Exists rather than a value it cannot know in advance.
render_targeting() {
  if [ "$relax_targeting" -eq 1 ]; then
    return 0
  fi
  if [ -z "$nodes" ]; then
    cat <<YAML
      nodeSelector:
        ${POOL_LABEL_KEY}: ${POOL_LABEL_VALUE}
YAML
  fi
  cat <<YAML
      tolerations:
        - key: ${BURST_TAINT_KEY}
          operator: Exists
          effect: NoSchedule
YAML
}

build_manifest() {
  local indented_source
  indented_source=$(sed -e 's/^/    /' -e 's/^ *$//' "$QUANTUM_SOURCE")
  cat <<YAML
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    ${QUANTUM_LABEL_KEY}: ${name}
data:
  quantum.py: |
${indented_source}
---
apiVersion: batch/v1
kind: Job
metadata:
  name: ${name}
  namespace: ${namespace}
  labels:
    ${QUANTUM_LABEL_KEY}: ${name}
spec:
  completions: ${replicas}
  parallelism: ${replicas}
  completionMode: Indexed
  backoffLimit: ${BACKOFF_LIMIT}
  ttlSecondsAfterFinished: ${JOB_TTL_S}
  template:
    metadata:
      labels:
        ${QUANTUM_LABEL_KEY}: ${name}
    spec:
      restartPolicy: Never
      affinity:
$(render_node_affinity)
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchLabels:
                  ${QUANTUM_LABEL_KEY}: ${name}
              topologyKey: ${HOSTNAME_LABEL_KEY}
$(render_targeting)
      securityContext:
        runAsNonRoot: true
        runAsUser: ${UNPRIVILEGED_UID}
        runAsGroup: ${UNPRIVILEGED_UID}
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: quantum
          image: ${QUANTUM_IMAGE}
          command: ["python3", "${PROGRAM_MOUNT_PATH}/quantum.py"]
          env:
            - name: PYTHONDONTWRITEBYTECODE
              value: "1"
            - name: QUANTUM_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: QUANTUM_POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
$(render_optional_env QUANTUM_SHARD_ITERATIONS "$shard_iterations")
$(render_optional_env QUANTUM_SEED "$seed")
$(render_optional_env QUANTUM_WORKERS "$workers")
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities:
              drop:
                - ALL
          resources:
            requests:
              cpu: ${CPU_REQUEST}
              memory: ${MEMORY_REQUEST}
            limits:
              memory: ${MEMORY_LIMIT}
          volumeMounts:
            - name: program
              mountPath: ${PROGRAM_MOUNT_PATH}
              readOnly: true
      volumes:
        - name: program
          configMap:
            name: ${name}
YAML
}

if [ "$render_only" -eq 1 ]; then
  build_manifest
  exit 0
fi

require_tools kubectl jq

run_dir="${out_dir}/${name}"
mkdir -p "$run_dir"
results_path="${run_dir}/results.jsonl"
manifest_path="${run_dir}/manifest.yaml"
run_params_path="${run_dir}/run-params.json"
: >"$results_path"

applied=0

cleanup() {
  local exit_code=$?
  trap - EXIT
  set +e
  if [ "$applied" -eq 1 ] && [ "$keep" -eq 0 ]; then
    kubectl -n "$namespace" delete job "$name" --ignore-not-found --cascade=foreground >/dev/null 2>&1
    kubectl -n "$namespace" delete configmap "$name" --ignore-not-found >/dev/null 2>&1
  elif [ "$applied" -eq 1 ]; then
    echo "run-quantum: leaving ${namespace}/${name} in place; delete the Job and ConfigMap by hand once read" >&2
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM HUP

write_run_params() {
  cat >"$run_params_path" <<JSON
{
  "name": "${name}",
  "namespace": "${namespace}",
  "replicas": ${replicas},
  "nodes": "${nodes}",
  "shardIterations": "${shard_iterations}",
  "seed": "${seed}",
  "workers": "${workers}",
  "image": "${QUANTUM_IMAGE}",
  "relaxedTargeting": $([ "$relax_targeting" -eq 1 ] && echo true || echo false),
  "startedAt": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
JSON
}

await_job_outcome() {
  local deadline="$1" json condition succeeded reported=""
  while :; do
    if json=$(kubectl -n "$namespace" get job "$name" -o json 2>/dev/null); then
      condition=$(printf '%s' "$json" | jq -r '[.status.conditions[]? | select(.status=="True") | select(.type=="Complete" or .type=="Failed") | .type][0] // empty')
      case "$condition" in
      Complete) echo complete; return 0 ;;
      Failed) echo failed; return 0 ;;
      esac
      succeeded=$(printf '%s' "$json" | jq -r '.status.succeeded // 0')
      if [ "$succeeded" != "$reported" ]; then
        echo "run-quantum: ${succeeded}/${replicas} units complete" >&2
        reported="$succeeded"
      fi
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      echo timeout
      return 0
    fi
    sleep "$POLL_INTERVAL_S"
  done
}

collect_results() {
  local pod
  while IFS= read -r pod; do
    [ -n "$pod" ] || continue
    kubectl -n "$namespace" logs "$pod" 2>/dev/null | jq -c . >>"$results_path" || true
  done < <(kubectl -n "$namespace" get pods -l "${QUANTUM_LABEL_KEY}=${name}" \
    --field-selector=status.phase=Succeeded -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
}

report_pending_pods() {
  echo "run-quantum: pod scheduling state:" >&2
  kubectl -n "$namespace" get pods -l "${QUANTUM_LABEL_KEY}=${name}" \
    -o custom-columns='NAME:.metadata.name,PHASE:.status.phase,NODE:.spec.nodeName,REASON:.status.conditions[0].reason' >&2 || true
}

verify_results() {
  local count checksums distinct nodes_seen distinct_nodes
  count=$(wc -l <"$results_path" | tr -d ' ')
  if [ "$count" -ne "$replicas" ]; then
    echo "run-quantum: FATAL collected ${count} result lines for ${replicas} requested units" >&2
    return 1
  fi

  checksums=$(jq -r '.checksum' "$results_path" | sort -u)
  distinct=$(printf '%s\n' "$checksums" | wc -l | tr -d ' ')
  if [ "$distinct" -ne 1 ]; then
    echo "run-quantum: FATAL the units disagreed on the result, which is a finding and not a rounding error:" >&2
    jq -r '"  " + .node + " " + .checksum' "$results_path" >&2
    return 1
  fi

  if [ -n "$expect_checksum" ] && [ "$checksums" != "$expect_checksum" ]; then
    echo "run-quantum: FATAL expected checksum ${expect_checksum}, got ${checksums}" >&2
    return 1
  fi

  nodes_seen=$(jq -r '.node' "$results_path")
  distinct_nodes=$(printf '%s\n' "$nodes_seen" | sort -u | wc -l | tr -d ' ')
  if [ "$distinct_nodes" -ne "$replicas" ]; then
    echo "run-quantum: FATAL ${replicas} units ran across ${distinct_nodes} distinct nodes; the replicas arm would be invalid" >&2
    return 1
  fi

  echo "run-quantum: ${replicas} unit(s) agreed on checksum ${checksums}" >&2
  jq -r '"  " + .node + "  workers=" + (.workers|tostring) + "  elapsed=" + (.elapsedSeconds|tostring) + "s"' "$results_path" >&2
  return 0
}

build_manifest >"$manifest_path"
write_run_params

echo "run-quantum: applying ${namespace}/${name} (replicas=${replicas}, targeting=$([ "$relax_targeting" -eq 1 ] && echo relaxed || echo "${nodes:-burst-nodes}"))" >&2
kubectl apply -f "$manifest_path" >/dev/null
applied=1

outcome=$(await_job_outcome "$(($(date +%s) + max_wait_s))")
collect_results

case "$outcome" in
complete) ;;
failed)
  echo "run-quantum: FATAL the Job reported Failed" >&2
  report_pending_pods
  exit 1
  ;;
timeout)
  echo "run-quantum: FATAL no terminal condition within ${max_wait_s}s" >&2
  report_pending_pods
  exit 1
  ;;
esac

verify_results
echo "run-quantum: artefacts in ${run_dir}" >&2

#!/usr/bin/env bash

readonly MINIMUM_BASH_MAJOR=4
if [ -z "${BASH_VERSINFO:-}" ] || [ "${BASH_VERSINFO[0]}" -lt "$MINIMUM_BASH_MAJOR" ]; then
  echo "${PROGRAM_NAME}: bash ${MINIMUM_BASH_MAJOR} or newer is required for associative arrays; run it inside 'nix develop', which provides one" >&2
  exit 1
fi

readonly POLL_INTERVAL_S=5
readonly CLEANUP_MAX_WAIT_S=300
readonly CLEANUP_POLL_INTERVAL_S=5
readonly HETZNER_POLL_FAILURE_LIMIT=5

readonly HETZNER_SECRET_NAMESPACE="horizon-system"
readonly HETZNER_SECRET_NAME="horizon-hetzner"
readonly OPERATOR_NAMESPACE="horizon-system"
readonly OPERATOR_DEPLOYMENT="horizon"
readonly LEASE_LABEL_KEY="horizon.dev/lease"
readonly BURST_TAINT_KEY="horizon.dev/burst"
readonly WATCHDOG_ARMED_ANNOTATION="horizon.dev/watchdog-armed"
readonly HETZNER_PRICING_URL="https://api.hetzner.cloud/v1/pricing"
readonly PROVIDER_CONFIG_RESOURCE="providerconfig"

readonly DNS_LABEL_PATTERN='^[a-z0-9]([-a-z0-9]*[a-z0-9])?$'
readonly POSITIVE_INTEGER_PATTERN='^[1-9][0-9]*$'
readonly NON_NEGATIVE_INTEGER_PATTERN='^(0|[1-9][0-9]*)$'
readonly SHA256_HEX_PATTERN='^[0-9a-f]{64}$'

hetzner_poll_failures=0
server_ever_seen=0
hetzner_fresh=0
ready_epoch=""
ready_source=""
node_names=()
declare -A hetzner_seen
declare -A hetzner_created
declare -A hetzner_absent_at
declare -A lease_seen
declare -A node_seen

die() {
  echo "${PROGRAM_NAME}: $1" >&2
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
  local subject="$1" value="$2" pattern="$3" expectation="$4"
  if ! [[ "$value" =~ $pattern ]]; then
    die "${subject} must be ${expectation}, got '${value}'"
  fi
}

require_tools() {
  local tool
  for tool in "$@"; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      die "$tool is not on PATH; run this script inside 'nix develop', which provides it"
    fi
  done
}

require_gnu_date() {
  if ! date -u -d "@0" +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
    die "GNU date is required; run this script inside 'nix develop', which provides coreutils"
  fi
}

fetch_provider_config_json() {
  local provider_ref="$1" json error
  if json=$(kubectl get "$PROVIDER_CONFIG_RESOURCE" "$provider_ref" -o json 2>/dev/null); then
    printf '%s' "$json"
    return 0
  fi
  error=$(kubectl get "$PROVIDER_CONFIG_RESOURCE" "$provider_ref" -o json 2>&1 >/dev/null | head -1)
  die "cannot read ${PROVIDER_CONFIG_RESOURCE}/${provider_ref} to validate --region/--size against the live catalogue: ${error}"
}

require_known_region() {
  local provider_ref="$1" region="$2" json="${3:-}" is_known regions
  [ -n "$json" ] || json=$(fetch_provider_config_json "$provider_ref")
  is_known=$(printf '%s' "$json" | jq -r --arg region "$region" \
    '[.status.instanceTypes[]?.region] | unique | any(. == $region)')
  if [ "$is_known" != "true" ]; then
    regions=$(printf '%s' "$json" | jq -r '[.status.instanceTypes[]?.region] | unique | join(", ")')
    die "region '${region}' is not offered by ${PROVIDER_CONFIG_RESOURCE}/${provider_ref}; it offers: ${regions}"
  fi
}

require_available_instance_type() {
  local provider_ref="$1" region="$2" size="$3" json match
  json=$(fetch_provider_config_json "$provider_ref")
  require_known_region "$provider_ref" "$region" "$json"
  match=$(printf '%s' "$json" | jq -r --arg region "$region" --arg size "$size" \
    '[.status.instanceTypes[]? | select(.region == $region and .name == $size)][0] // empty')
  if [ -z "$match" ]; then
    die "'${size}' in region '${region}' is not in ${PROVIDER_CONFIG_RESOURCE}/${provider_ref}'s published catalogue; see .status.instanceTypes on that object for what is offered in this region"
  fi
  if [ "$(printf '%s' "$match" | jq -r '.available')" != "true" ]; then
    die "'${size}' in region '${region}' is in the catalogue but the provider marks it unavailable; pick a different size from ${PROVIDER_CONFIG_RESOURCE}/${provider_ref}'s .status.instanceTypes"
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
    echo "${PROGRAM_NAME}: cannot parse duration '${original}', expected whole hour, minute and second parts such as 10m or 1h30m" >&2
    return 1
  fi
  echo "$total"
}

load_hcloud_token() {
  local token
  token="$(kubectl get secret "$HETZNER_SECRET_NAME" -n "$HETZNER_SECRET_NAMESPACE" -o jsonpath='{.data.token}' | base64 -d)"
  if [ -z "$token" ]; then
    echo "${PROGRAM_NAME}: empty Hetzner token from secret ${HETZNER_SECRET_NAMESPACE}/${HETZNER_SECRET_NAME}" >&2
    exit 1
  fi
  export HCLOUD_TOKEN="$token"
}

instant_of() {
  date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ
}

write_csv_row() {
  local field row=""
  for field in "$@"; do
    case "$field" in
    *[,\"]* | *$'\n'*) field="\"${field//\"/\"\"}\"" ;;
    esac
    row+="${row:+,}${field}"
  done
  printf '%s\n' "$row" >>"$csv_path"
}

csv_header() {
  echo "timestamp,elapsed_s,source,object,field,value" >"$csv_path"
}

emit_event() {
  local now_epoch now_iso elapsed
  now_epoch=$(date +%s)
  now_iso=$(instant_of "$now_epoch")
  elapsed=$((now_epoch - start_epoch))
  write_csv_row "$now_iso" "$elapsed" "$1" "$2" "$3" "$4"
}

emit_event_at() {
  local elapsed="$5" iso
  iso=$(instant_of "$((start_epoch + elapsed))")
  write_csv_row "$iso" "$elapsed" "$1" "$2" "$3" "$4"
}

hetzner_active_count() {
  local n=0 k
  for k in "${!hetzner_seen[@]}"; do
    [ "${hetzner_seen[$k]}" != "absent" ] && n=$((n + 1))
  done
  echo "$n"
}

record_hetzner_poll_failure() {
  hetzner_poll_failures=$((hetzner_poll_failures + 1))
  emit_event hetzner "$name" poll-failed "$hetzner_poll_failures"
  if [ "$hetzner_poll_failures" -ge "$HETZNER_POLL_FAILURE_LIMIT" ]; then
    echo "${PROGRAM_NAME}: FATAL the Hetzner API failed ${hetzner_poll_failures} times in a row and it is the only authority on whether a server still bills" >&2
    exit 1
  fi
  echo "${PROGRAM_NAME}: WARNING ${1} (${hetzner_poll_failures} in a row)" >&2
}

# A failed query must never leave the seen map looking like an empty estate, because that reads as a teardown the harness would then report as measured.
poll_hetzner() {
  local json count rows sname sstatus screated found s i
  if ! json=$(hcloud server list -l "${LEASE_LABEL_KEY}=${name}" -o json 2>/dev/null) ||
    ! count=$(printf '%s' "$json" | jq 'length' 2>/dev/null) ||
    ! [[ "$count" =~ $NON_NEGATIVE_INTEGER_PATTERN ]] ||
    ! rows=$(printf '%s' "$json" | jq -r '.[] | [.name, .status, .created] | @tsv' 2>/dev/null); then
    record_hetzner_poll_failure "the Hetzner API query failed"
    return 1
  fi

  local seen_names=() seen_statuses=() seen_created=()
  while IFS=$'\t' read -r sname sstatus screated; do
    [ -n "$sname" ] && [ -n "$sstatus" ] || continue
    seen_names+=("$sname")
    seen_statuses+=("$sstatus")
    seen_created+=("$screated")
  done <<<"$rows"

  if [ "${#seen_names[@]}" -ne "$count" ]; then
    record_hetzner_poll_failure "the Hetzner listing claimed ${count} servers but described ${#seen_names[@]}"
    return 1
  fi

  hetzner_poll_failures=0
  [ "$count" -gt 0 ] && server_ever_seen=1

  for i in "${!seen_names[@]}"; do
    sname="${seen_names[$i]}"
    sstatus="${seen_statuses[$i]}"
    screated="${seen_created[$i]}"
    if [ -n "$screated" ] && [ -z "${hetzner_created[$sname]:-}" ]; then
      hetzner_created[$sname]="$screated"
      emit_event hetzner "$sname" created "$screated"
    fi
    if [ "${hetzner_seen[$sname]:-}" != "$sstatus" ]; then
      emit_event hetzner "$sname" status "$sstatus"
      hetzner_seen[$sname]="$sstatus"
    fi
  done

  for s in "${!hetzner_seen[@]}"; do
    found=0
    for sname in "${seen_names[@]:-}"; do
      [ "$sname" = "$s" ] && found=1 && break
    done
    if [ "$found" -eq 0 ] && [ "${hetzner_seen[$s]}" != "absent" ]; then
      emit_event hetzner "$s" status absent
      hetzner_seen[$s]="absent"
      hetzner_absent_at[$s]="$(date +%s)"
    fi
  done
}

record_ready_instant() {
  local epoch="$1" source="$2"
  [ "$ready_source" = lease-readyAt ] && return 0
  ready_epoch="$epoch"
  ready_source="$source"
  emit_event harness "$name" ready-instant "$(instant_of "$epoch") via ${source}"
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
      require_pattern "the nodeName reported in .status.instances[]" "$node" "$DNS_LABEL_PATTERN" \
        "a lowercase alphanumeric DNS label, because it is interpolated into a generated manifest"
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

poll_all() {
  hetzner_fresh=0
  poll_hetzner && hetzner_fresh=1
  poll_lease
  poll_node
}

observe_until_estate_empty() {
  local deadline="$1" hook="${2:-}"
  while :; do
    poll_all
    if [ -n "$hook" ]; then
      "$hook"
    fi

    if [ "$hetzner_fresh" -eq 1 ] && [ "$server_ever_seen" -eq 1 ] && [ "$(hetzner_active_count)" -eq 0 ]; then
      return 0
    fi
    if [ "$(date +%s)" -ge "$deadline" ]; then
      return 1
    fi
    sleep "$POLL_INTERVAL_S"
  done
}

ready_node_count() {
  local node n=0
  for node in "${node_names[@]:-}"; do
    [ "${node_seen[$node,ready]:-}" = True ] && n=$((n + 1))
  done
  echo "$n"
}

capture_operator_log_so_far() {
  local until
  until=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  kubectl -n "$OPERATOR_NAMESPACE" logs "deploy/${OPERATOR_DEPLOYMENT}" --since-time="$operator_log_captured_until" >>"$operator_log_path" 2>/dev/null || true
  operator_log_captured_until="$until"
}

export_hetzner_pricing() {
  if curl -sf -H "Authorization: Bearer ${HCLOUD_TOKEN}" "$HETZNER_PRICING_URL" -o "$hetzner_pricing_path"; then
    echo "${PROGRAM_NAME}: wrote current Hetzner pricing to ${hetzner_pricing_path} (rates at export time, not a historical invoice: the Cloud API exposes no per-resource usage/invoice endpoint reachable with a project token)" >&2
    emit_event harness "$name" export-pricing ok
  else
    echo "${PROGRAM_NAME}: WARNING Hetzner pricing endpoint unreachable, skipping" >&2
    emit_event harness "$name" export-pricing failed
  fi
}

run_export() {
  local label="$1"
  shift
  if "$@"; then
    return 0
  fi
  echo "${PROGRAM_NAME}: WARNING the ${label} export failed; the remaining exports still run" >&2
  emit_event harness "$name" export-failed "$label" || true
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
    echo "${PROGRAM_NAME}: FATAL could not list servers to force-delete; delete them by hand now" >&2
    return 1
  fi
  for id in $ids; do
    hcloud server delete "$id" || echo "${PROGRAM_NAME}: FATAL forced delete of server ${id} failed, delete it by hand now" >&2
  done
}

# Callers reach this from a trap that has already disabled errexit, so every step must tolerate a failing query rather than abandoning the delete.
release_lease_and_verify_estate_empty() {
  echo "${PROGRAM_NAME}: cleanup: verifying no server remains for lease ${name}" >&2
  kubectl delete capacitylease "$name" --ignore-not-found --wait=false >/dev/null 2>&1

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
    echo "${PROGRAM_NAME}: verified zero servers for lease ${name}" >&2
    return 0
  fi

  if [ "$count" = unknown ]; then
    echo "${PROGRAM_NAME}: FATAL could not determine how many servers exist for lease ${name} after ${CLEANUP_MAX_WAIT_S}s" >&2
  else
    echo "${PROGRAM_NAME}: FATAL ${count} server(s) still exist for lease ${name} after ${CLEANUP_MAX_WAIT_S}s" >&2
  fi
  echo "${PROGRAM_NAME}: inspect with: hcloud server list -l ${LEASE_LABEL_KEY}=${name}" >&2
  echo "${PROGRAM_NAME}: forcing hcloud delete as last resort" >&2
  force_delete_lease_servers
  return 1
}

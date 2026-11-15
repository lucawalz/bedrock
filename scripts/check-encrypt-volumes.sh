#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

script=scripts/encrypt-volumes.sh
paperless_volumes=(data media export consume)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/bin"
cat > "$work/bin/kubectl" <<'FAKE'
#!/bin/sh
echo "kubectl $*" >> "$FAKE_LOG"
case "$*" in "get pv pv-"*-encrypted" "*) [ -z "$FAKE_OLD_PV_UNREADABLE" ] || exit 1 ;; esac
case "$*" in
  "apply -f -") cat >> "$FAKE_APPLIED" ;;
  "get statefulset "*".spec.replicas"* | "get deployment "*".spec.replicas"*) echo "${FAKE_REPLICAS:-1}" ;;
  "get statefulset "*".image"* | "get deployment "*".image"*) echo "$FAKE_IMAGE" ;;
  "get statefulset "*"persistentVolumeClaim.claimName"* | "get deployment "*"persistentVolumeClaim.claimName"*)
    volume="$(echo "$*" | sed 's/.*@.name=="\([a-z]*\)".*/\1/')"
    if [ -n "$FAKE_UNMOUNTED" ]; then echo other-claim
    elif [ "$5" = llm ]; then echo open-webui-encrypted
    else echo "paperless-ngx-$volume-encrypted"; fi ;;
  "get secret "*) [ -z "$FAKE_SECRET_MISSING" ] || exit 1; echo "secret/$3" ;;
  "get pvc "*".status.phase"*)
    case "$3" in
      *-encrypted) side=old ;;
      *) side=new ;;
    esac
    if [ "$FAKE_UNBOUND" = "$side" ]; then echo Pending; else echo Bound; fi ;;
  "get pvc "*".spec.volumeName"*) echo "pv-$3" ;;
  "get pv "*"nodePublishSecretRef"*)
    case "$3" in
      *-encrypted) echo "${FAKE_OLD_KEY-longhorn-crypto-legacy}" ;;
      *) echo "${FAKE_NEW_KEY-longhorn-crypto}" ;;
    esac ;;
  "get pv "*"persistentVolumeReclaimPolicy"*) echo "${FAKE_OLD_RECLAIM:-Retain}" ;;
  "get pod "*"-o jsonpath"*) echo "${FAKE_COPY_PHASE:-Succeeded}" ;;
  "get pod "*"-l "*) ;;
  "get pod "*) [ -n "$FAKE_COPY_POD_EXISTS" ] || exit 1 ;;
  "scale "* | "logs "* | "delete pod "* | "get events "*) ;;
  *) echo "unexpected kubectl $*" >&2; exit 1 ;;
esac
FAKE
cat > "$work/bin/flux" <<'FAKE'
#!/bin/sh
echo "flux $*" >> "$FAKE_LOG"
FAKE
cat > "$work/bin/yq" <<'FAKE'
#!/bin/sh
echo "unexpected yq $*" >&2
exit 1
FAKE
cat > "$work/bin/sleep" <<'FAKE'
#!/bin/sh
echo "sleep $*" >> "$FAKE_LOG"
FAKE
chmod +x "$work"/bin/*

run() {
  local app="$1"; shift
  : > "$work/log"
  : > "$work/applied"
  FAKE_LOG="$work/log" FAKE_APPLIED="$work/applied" FAKE_IMAGE="ghcr.io/$app/$app:1.0" \
    PATH="$work/bin:$PATH" bash "$script" "$app" "$@" > "$work/output" 2>&1 <<< "$app"
}

refused() {
  local reason="$1"; shift
  if run "$@"; then fail "$reason was not refused"; fi
  if grep -qE '^(kubectl (apply|scale)|flux suspend)' "$work/log"; then fail "$reason still changed the cluster: $(cat "$work/log")"; fi
}

rolled_back() {
  local reason="$1"; shift
  if run "$@"; then fail "$reason succeeded"; fi
  grep -q "^kubectl scale statefulset open-webui -n llm --replicas 1$" "$work/log" || fail "$reason did not scale open-webui back: $(cat "$work/log")"
  grep -q '^flux resume helmrelease open-webui -n llm$' "$work/log" || fail "$reason did not resume the HelmRelease"
  grep -q '^flux resume kustomization llm$' "$work/log" || fail "$reason did not resume the Kustomization"
  ! grep -q 'Copied and verified' "$work/output" || fail "$reason printed the success line"
}

claim_of() {
  grep -A3 "name: $1$" "$work/applied" | sed -n 's/.*claimName: //p' | head -n 1
}

run open-webui || { cat "$work/output" >&2; fail "a valid open-webui run failed"; }
[ "$(claim_of old-data)" = open-webui-encrypted ] || fail "open-webui does not copy from open-webui-encrypted"
[ "$(claim_of new-data)" = open-webui ] || fail "open-webui does not copy onto open-webui"
grep -q 'flux suspend kustomization llm' "$work/log" || fail "open-webui did not suspend its Kustomization"
grep -qF 'open-webui-encrypted -> open-webui' "$work/output" || fail "the next steps do not name the open-webui claim swap"

run paperless-ngx || { cat "$work/output" >&2; fail "a valid paperless-ngx run failed"; }
for volume in "${paperless_volumes[@]}"; do
  old="$(grep -A3 "name: old-$volume$" "$work/applied" | tr -d ' ' | tr '\n' ' ')"
  new="$(grep -A2 "name: new-$volume$" "$work/applied" | tr -d ' ' | tr '\n' ' ')"
  case "$old" in *"mountPath:/old/$volume readOnly:true"*) ;; *) fail "the copy pod does not mount old $volume read-only: $(cat "$work/applied")" ;; esac
  case "$new" in *"mountPath:/new/$volume"*) ;; *) fail "the copy pod does not mount new $volume" ;; esac
  [ "$(claim_of "old-$volume")" = "paperless-ngx-$volume-encrypted" ] || fail "paperless-ngx $volume does not copy from paperless-ngx-$volume-encrypted"
  [ "$(claim_of "new-$volume")" = "paperless-ngx-$volume" ] || fail "paperless-ngx $volume does not copy onto paperless-ngx-$volume"
  grep -qxF "  paperless-ngx-$volume-encrypted -> paperless-ngx-$volume" "$work/output" || fail "the next steps do not name the $volume claim swap"
done
grep -q 'kubectl scale deployment paperless-ngx -n paperless --replicas 0' "$work/log" || fail "paperless-ngx was not scaled down"
grep -q 'flux suspend helmrelease paperless-ngx -n paperless' "$work/log" || fail "paperless-ngx did not suspend its HelmRelease"
grep -q 'runAsUser: 0' "$work/applied" || fail "the paperless-ngx copy pod does not run as root"
grep -q 'app.kubernetes.io/instance: paperless-ngx' "$work/applied" || fail "the copy pod lacks the paperless-ngx labels"
grep -q 'image: ghcr.io/paperless-ngx/paperless-ngx:1.0' "$work/applied" || fail "the copy pod does not use the paperless-ngx image"
grep -q 'add: \["CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID"\]' "$work/applied" || fail "the root copy pod cannot keep other owners"
! grep -q 'flux resume' "$work/log" || fail "a successful copy resumed Flux"

FAKE_OLD_KEY="" run open-webui || { cat "$work/output" >&2; fail "an unencrypted old claim was refused"; }

refused "an unknown app" grafana
grep -q 'known apps: open-webui paperless-ngx' "$work/output" || fail "the unknown app refusal does not list the apps"
FAKE_REPLICAS=0 refused "a workload already at 0" open-webui
FAKE_UNMOUNTED=1 refused "an old claim the workload does not mount" paperless-ngx
FAKE_NEW_KEY=longhorn-crypto-legacy refused "a new claim on the legacy key" paperless-ngx
FAKE_NEW_KEY="" refused "an unencrypted new claim" open-webui
FAKE_OLD_KEY=longhorn-crypto refused "an old claim already on the new key" open-webui
FAKE_OLD_RECLAIM=Delete refused "an old claim whose PV is reclaimed with Delete" paperless-ngx
grep -q 'not Retain' "$work/output" || fail "the Delete refusal does not name Retain: $(cat "$work/output")"
FAKE_OLD_PV_UNREADABLE=1 refused "an old claim whose PV cannot be read" open-webui
grep -q 'cannot read the PV of pvc open-webui-encrypted' "$work/output" || fail "an unreadable old PV was not named: $(cat "$work/output")"
FAKE_UNBOUND=old refused "an old claim that is not bound" paperless-ngx
FAKE_UNBOUND=new refused "a new claim that is not bound" paperless-ngx
FAKE_SECRET_MISSING=1 refused "a missing target key Secret" open-webui
FAKE_COPY_POD_EXISTS=1 refused "an existing copy pod" open-webui

FAKE_COPY_PHASE=Failed rolled_back "a failed copy pod" open-webui
FAKE_COPY_PHASE=Pending rolled_back "a copy that never finishes" open-webui
grep -q 'did not finish' "$work/output" || fail "the copy timeout does not say so: $(cat "$work/output")"

if command -v kubeconform >/dev/null 2>&1; then
  for app in open-webui paperless-ngx; do
    PATH="$work/bin:$PATH" bash "$script" "$app" --dry-run > "$work/output" 2>&1 || { cat "$work/output" >&2; fail "the $app dry run failed"; }
    grep -q 'Valid: 1, Invalid: 0, Errors: 0' "$work/output" || fail "kubeconform did not accept the $app copy pod: $(cat "$work/output")"
  done
else
  echo "kubeconform is not on PATH; skipping the dry-run validation"
fi

echo "encrypt-volumes refuses every unsafe start and copies legacy-key volumes onto new-key twins."

#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage="usage: paperless-encrypt.sh [--dry-run]"

NAMESPACE=paperless
DEPLOYMENT=paperless-ngx
HELMRELEASE=paperless-ngx
KUSTOMIZATION=paperless
VOLUMES=(data media consume export)
ENCRYPTED_CLASS=longhorn-encrypted
KEY_NAMESPACE=longhorn-system
KEY_SECRET=longhorn-crypto
COPY_POD=paperless-encrypt-copy
# paperless runs as USERMAP_UID and USERMAP_GID, which own every file on the volumes
PAPERLESS_UID=1000
PAPERLESS_GID=1000
DRY_RUN_IMAGE=ghcr.io/paperless-ngx/paperless-ngx:dry-run
SCALE_DOWN_TIMEOUT_SECONDS=300
COPY_TIMEOUT_SECONDS=3600
POLL_SECONDS=10

dry_run=false
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
done

if $dry_run; then
  require_tools kubeconform
else
  require_tools kubectl flux yq
fi

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

old_claim() { echo "paperless-ngx-$1"; }
new_claim() { echo "paperless-ngx-$1-encrypted"; }

copy_script() {
  cat <<SCRIPT
set -euo pipefail
manifest() (
  cd "\$1"
  find . -mindepth 1 \( -path ./lost+found -prune \) -o \( -type f -printf '%y %m %U:%G %n %s %T@ %p\n' \) -o -printf '%y %m %U:%G %p -> %l\n' | sort
  find . -path ./lost+found -prune -o -type f -links +1 -printf '%i %p\n' | sort -k2 | awk '{ inode = \$1; sub(/^[^ ]+ /, ""); print (inode in first ? first[inode] : (first[inode] = \$0)) " <= " \$0 }'
  find . -path ./lost+found -prune -o -type f -print0 | sort -z | xargs -0r sha256sum
)
for volume in ${VOLUMES[*]}; do
  find "/old/\$volume" -mindepth 1 -maxdepth 1 ! -name lost+found -exec cp -a -t "/new/\$volume" {} +
  manifest "/old/\$volume" > "/tmp/\$volume.old"
  manifest "/new/\$volume" > "/tmp/\$volume.new"
  diff "/tmp/\$volume.old" "/tmp/\$volume.new" || { echo "\$volume: the encrypted copy differs from the original"; exit 1; }
  echo "\$volume: \$(grep -c '^f ' "/tmp/\$volume.old" || true) files, \$(awk '\$1 == "f" { sum += \$5 } END { print sum + 0 }' "/tmp/\$volume.old") bytes; paths, modes, owners, link targets, hard links, sizes and checksums match"
done
SCRIPT
}

copy_pod() {
  local image="$1" volume
  cat <<MANIFEST
apiVersion: v1
kind: Pod
metadata:
  name: ${COPY_POD}
  namespace: ${NAMESPACE}
  labels:
    app.kubernetes.io/name: ${COPY_POD}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  enableServiceLinks: false
  nodeSelector:
    bedrock.io/storage: "true"
  securityContext:
    runAsNonRoot: true
    runAsUser: ${PAPERLESS_UID}
    runAsGroup: ${PAPERLESS_GID}
    fsGroup: ${PAPERLESS_GID}
    fsGroupChangePolicy: OnRootMismatch
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: copy
      image: ${image}
      command: ["bash", "-c"]
      args:
        - |
$(copy_script | sed 's/^/          /')
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 100m
          memory: 128Mi
        limits:
          memory: 512Mi
      volumeMounts:
        - name: tmp
          mountPath: /tmp
MANIFEST
  for volume in "${VOLUMES[@]}"; do
    printf '        - name: old-%s\n          mountPath: /old/%s\n          readOnly: true\n' "$volume" "$volume"
    printf '        - name: new-%s\n          mountPath: /new/%s\n' "$volume" "$volume"
  done
  printf '  volumes:\n    - name: tmp\n      emptyDir: {}\n'
  for volume in "${VOLUMES[@]}"; do
    printf '    - name: old-%s\n      persistentVolumeClaim:\n        claimName: %s\n        readOnly: true\n' "$volume" "$(old_claim "$volume")"
    printf '    - name: new-%s\n      persistentVolumeClaim:\n        claimName: %s\n' "$volume" "$(new_claim "$volume")"
  done
}

if $dry_run; then
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT
  copy_pod "$DRY_RUN_IMAGE" > "$work/pod.yaml"
  cat "$work/pod.yaml"
  kubeconform -strict -summary "$work/pod.yaml"
  exit 0
fi

pvc_field() {
  kubectl get pvc "$1" -n "$NAMESPACE" -o jsonpath="{$2}"
}

deploy_field() {
  kubectl get deploy "$DEPLOYMENT" -n "$NAMESPACE" -o jsonpath="{$1}"
}

replicas="$(deploy_field .spec.replicas)"
[ "$replicas" -gt 0 ] || fail "$DEPLOYMENT is already scaled to 0, perhaps by an earlier run; finish or undo that run first"
kubectl get secret "$KEY_SECRET" -n "$KEY_NAMESPACE" >/dev/null || fail "secret $KEY_NAMESPACE/$KEY_SECRET is missing"
for volume in "${VOLUMES[@]}"; do
  old="$(old_claim "$volume")"
  new="$(new_claim "$volume")"
  mounted="$(deploy_field ".spec.template.spec.volumes[?(@.name==\"$volume\")].persistentVolumeClaim.claimName")"
  [ "$mounted" = "$old" ] || fail "$DEPLOYMENT mounts $mounted as $volume, not $old; the copy only runs before the claim swap"
  [ "$(pvc_field "$old" .status.phase)" = Bound ] || fail "pvc $old is not bound"
  [ "$(pvc_field "$old" '.metadata.annotations.helm\.sh/resource-policy')" = keep ] \
    || fail "pvc $old lacks helm.sh/resource-policy keep, so swapping the claims would delete it"
  [ "$(pvc_field "$new" .status.phase)" = Bound ] || fail "pvc $new is not bound"
  [ "$(pvc_field "$new" .spec.storageClassName)" = "$ENCRYPTED_CLASS" ] || fail "pvc $new is not on $ENCRYPTED_CLASS"
done
! kubectl get pod "$COPY_POD" -n "$NAMESPACE" >/dev/null 2>&1 || fail "pod $COPY_POD already exists; delete it first"
image="$(deploy_field '.spec.template.spec.containers[0].image')"

echo "This suspends Flux for $KUSTOMIZATION, scales $DEPLOYMENT to 0 and copies each paperless volume onto its encrypted twin."
echo "On success paperless stays down and Flux stays suspended until the claims are swapped; on failure both are restored."
read -r -p "Type $NAMESPACE to continue: " answer
[ "$answer" = "$NAMESPACE" ] || { echo "Aborted."; exit 1; }

copied=false
finish() {
  set +e
  kubectl delete pod "$COPY_POD" -n "$NAMESPACE" --ignore-not-found --wait
  if ! $copied; then
    kubectl scale deploy "$DEPLOYMENT" -n "$NAMESPACE" --replicas "$replicas"
    flux resume helmrelease "$HELMRELEASE" -n "$NAMESPACE"
    flux resume kustomization "$KUSTOMIZATION"
  fi
}
trap finish EXIT

flux suspend kustomization "$KUSTOMIZATION"
flux suspend helmrelease "$HELMRELEASE" -n "$NAMESPACE"
kubectl scale deploy "$DEPLOYMENT" -n "$NAMESPACE" --replicas 0
deadline=$((SECONDS + SCALE_DOWN_TIMEOUT_SECONDS))
while [ -n "$(kubectl get pod -n "$NAMESPACE" -l "app.kubernetes.io/instance=$DEPLOYMENT,app.kubernetes.io/name=$DEPLOYMENT" -o name)" ]; do
  [ "$SECONDS" -lt "$deadline" ] || fail "$DEPLOYMENT pods still exist after ${SCALE_DOWN_TIMEOUT_SECONDS}s"
  sleep "$POLL_SECONDS"
done

copy_pod "$image" | kubectl apply -f -
waited=0
while :; do
  phase="$(kubectl get pod "$COPY_POD" -n "$NAMESPACE" -o jsonpath='{.status.phase}')"
  case "$phase" in
    Succeeded) break ;;
    Failed)
      kubectl logs "$COPY_POD" -n "$NAMESPACE" >&2 || true
      fail "copy pod failed; the original volumes are untouched" ;;
  esac
  if [ "$waited" -ge "$COPY_TIMEOUT_SECONDS" ]; then
    kubectl get events -n "$NAMESPACE" --field-selector "involvedObject.name=$COPY_POD" >&2 || true
    fail "copy pod did not finish within ${COPY_TIMEOUT_SECONDS}s"
  fi
  sleep "$POLL_SECONDS"
  waited=$((waited + POLL_SECONDS))
done
kubectl logs "$COPY_POD" -n "$NAMESPACE"
copied=true

echo "Copied and verified. $DEPLOYMENT stays at 0 and Flux stays suspended; the original claims are untouched."
echo "Next: apply the claim swap, commit and push it, then run:"
echo "  flux resume kustomization $KUSTOMIZATION && flux resume helmrelease $HELMRELEASE -n $NAMESPACE"

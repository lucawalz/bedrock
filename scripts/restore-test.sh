#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage="usage: restore-test.sh [--dry-run] [--max-age <n>s|m|h|d] postgres|longhorn|etcd|dumps|all"

POSTGRES_NAMESPACE=postgres
POSTGRES_SOURCE_CLUSTER=postgres
POSTGRES_ARCHIVE_SERVER=postgres-2026-11
POSTGRES_RESTORE_CLUSTER=postgres-restore-test
POSTGRES_OBJECT_STORE=postgres-backup
POSTGRES_RESTORE_TIMEOUT=30m
# Migration history only changes on upgrades, so recent writes lost to WAL recovery cannot cause a mismatch.
POSTGRES_CHECKS=("pocket-id schema_migrations" "paperless django_migrations")

LONGHORN_NAMESPACE=longhorn-system
LONGHORN_PVC_NAMESPACE=paperless
LONGHORN_DEPLOYMENT=paperless-ngx
LONGHORN_DEPLOYMENT_VOLUME=data
LONGHORN_RESTORE_VOLUME=restore-test
LONGHORN_RESTORE_TIMEOUT_SECONDS=1800
LONGHORN_MOUNT_TIMEOUT_SECONDS=600
LONGHORN_POLL_SECONDS=10
LONGHORN_KEY_SECRET=longhorn-crypto
LONGHORN_WRONG_KEY_SECRET=restore-test-wrong-key
LONGHORN_WRONG_KEY_BYTES=32
LONGHORN_KEY_ATTEMPT=restore-test-key
LONGHORN_WRONG_KEY_ATTEMPT=restore-test-wrong-key
LONGHORN_READER_UID=1000
LONGHORN_DRY_RUN_IMAGE=ghcr.io/paperless-ngx/paperless-ngx:dry-run
LONGHORN_DRY_RUN_SIZE_BYTES=$((5 * 1024 ** 3))

DUMPS_GNUPGHOME=/Volumes/bedrock-keys/bedrock/gnupg-postgres-dumps
DUMPS_BUCKET=bedrock-postgres
DUMPS_PREFIX=dumps
DUMPS_CREDENTIALS_SECRET=postgres-backup-s3
DUMPS_SCRATCH_DATABASE=restore_test_dumps

ETCD_S3_BUCKET=bedrock-etcd
ETCD_S3_PREFIX=etcd-snapshots
SECONDS_PER_MINUTE=60
SECONDS_PER_HOUR=3600
SECONDS_PER_DAY=86400
ETCD_MAX_AGE_SECONDS=$((13 * SECONDS_PER_HOUR))

API_SERVER_CIDRS=(10.20.0.10/32 10.20.0.11/32 10.20.0.12/32)
PRIVATE_CIDRS=(10.42.0.0/16 10.43.0.0/16 10.20.0.0/24 10.30.0.0/24 192.168.2.0/24)

dry_run=false
command=""
max_age=""
max_age_seconds=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=true ;;
    --max-age)
      [ "$#" -ge 2 ] && [[ "$2" =~ ^([0-9]+)([smhd])$ ]] || { echo "$usage" >&2; exit 2; }
      max_age="$2"
      case "${BASH_REMATCH[2]}" in
        s) unit=1 ;;
        m) unit="$SECONDS_PER_MINUTE" ;;
        h) unit="$SECONDS_PER_HOUR" ;;
        d) unit="$SECONDS_PER_DAY" ;;
      esac
      max_age_seconds=$((10#${BASH_REMATCH[1]} * unit))
      shift
      ;;
    postgres | longhorn | etcd | dumps | all) command="$1" ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
  shift
done
[ -n "$command" ] || { echo "$usage" >&2; exit 2; }

if $dry_run; then
  require_tools kubeconform
else
  require_tools kubectl yq
fi

work="$(mktemp -d)"
cleanups=()
cleanup() {
  local step
  for step in "${cleanups[@]}"; do
    "$step" || echo "cleanup step $step failed" >&2
  done
  rm -rf "$work"
}
trap cleanup EXIT

restore_network_policy() {
  local cidr
  cat <<MANIFEST
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-${POSTGRES_RESTORE_CLUSTER}-egress
  namespace: ${POSTGRES_NAMESPACE}
spec:
  podSelector:
    matchLabels:
      cnpg.io/cluster: ${POSTGRES_RESTORE_CLUSTER}
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: cnpg-system
      ports:
        - protocol: TCP
          port: 9443
    - to:
MANIFEST
  for cidr in "${API_SERVER_CIDRS[@]}"; do
    printf '        - ipBlock:\n            cidr: %s\n' "$cidr"
  done
  cat <<MANIFEST
      ports:
        - protocol: TCP
          port: 6443
    - to:
        - ipBlock:
            cidr: 0.0.0.0/0
            except:
MANIFEST
  for cidr in "${PRIVATE_CIDRS[@]}"; do
    printf '              - %s\n' "$cidr"
  done
  cat <<MANIFEST
      ports:
        - protocol: TCP
          port: 443
MANIFEST
}

restore_cluster() {
  cat <<MANIFEST
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: ${POSTGRES_RESTORE_CLUSTER}
  namespace: ${POSTGRES_NAMESPACE}
spec:
  instances: 1
  storage:
    size: 8Gi
    storageClass: longhorn-disposable
  resources:
    requests:
      cpu: 100m
      memory: 256Mi
    limits:
      memory: 768Mi
  bootstrap:
    recovery:
      source: origin
  externalClusters:
    - name: origin
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: ${POSTGRES_OBJECT_STORE}
          serverName: ${POSTGRES_ARCHIVE_SERVER}
MANIFEST
}

longhorn_volume() {
  local backup_url="$1" size="$2"
  cat <<MANIFEST
apiVersion: longhorn.io/v1beta2
kind: Volume
metadata:
  name: ${LONGHORN_RESTORE_VOLUME}
  namespace: ${LONGHORN_NAMESPACE}
spec:
  fromBackup: "${backup_url}"
  size: "${size}"
  numberOfReplicas: 1
  dataEngine: v1
  frontend: blockdev
  accessMode: rwo
  encrypted: true
MANIFEST
}

wrong_key_secret() {
  cat <<MANIFEST
apiVersion: v1
kind: Secret
metadata:
  name: ${LONGHORN_WRONG_KEY_SECRET}
  namespace: ${LONGHORN_NAMESPACE}
type: Opaque
stringData:
  CRYPTO_KEY_PROVIDER: secret
  CRYPTO_KEY_VALUE: "$(od -An -tx1 -N"$LONGHORN_WRONG_KEY_BYTES" /dev/urandom | tr -d ' \n')"
MANIFEST
}

mount_attempt() {
  local name="$1" secret="$2" size="$3" image="$4"
  cat <<MANIFEST
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${name}
spec:
  capacity:
    storage: "${size}"
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: ""
  claimRef:
    namespace: ${LONGHORN_PVC_NAMESPACE}
    name: ${name}
  csi:
    driver: driver.longhorn.io
    volumeHandle: ${LONGHORN_RESTORE_VOLUME}
    fsType: ext4
    nodeStageSecretRef:
      name: ${secret}
      namespace: ${LONGHORN_NAMESPACE}
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${name}
  namespace: ${LONGHORN_PVC_NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: ""
  volumeName: ${name}
  resources:
    requests:
      storage: "${size}"
---
apiVersion: v1
kind: Pod
metadata:
  name: ${name}
  namespace: ${LONGHORN_PVC_NAMESPACE}
  labels:
    app.kubernetes.io/name: ${name}
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  enableServiceLinks: false
  nodeSelector:
    bedrock.io/storage: "true"
  securityContext:
    runAsNonRoot: true
    runAsUser: ${LONGHORN_READER_UID}
    runAsGroup: ${LONGHORN_READER_UID}
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: read
      image: ${image}
      command: ["bash", "-c"]
      args:
        - |
          entries="\$(ls -A /restore | grep -cvx lost+found)"
          echo "\$entries entries"
          [ "\$entries" -gt 0 ]
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
      resources:
        requests:
          cpu: 10m
          memory: 16Mi
        limits:
          memory: 64Mi
      volumeMounts:
        - name: restore
          mountPath: /restore
          readOnly: true
  volumes:
    - name: restore
      persistentVolumeClaim:
        claimName: ${name}
        readOnly: true
MANIFEST
}

validate() {
  local file="$1"
  local locations=(-schema-location default)
  [ -z "${CRD_SCHEMAS:-}" ] || locations+=(-schema-location "$CRD_SCHEMAS/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")
  kubeconform -strict -ignore-missing-schemas "${locations[@]}" -summary "$file"
}

dry_run_manifests() {
  local name
  restore_network_policy > "$work/netpol.yaml"
  restore_cluster > "$work/cluster.yaml"
  longhorn_volume "s3://example@auto/?backup=backup-0&volume=pvc-0" "$LONGHORN_DRY_RUN_SIZE_BYTES" > "$work/volume.yaml"
  wrong_key_secret | sed 's/CRYPTO_KEY_VALUE: .*/CRYPTO_KEY_VALUE: redacted/' > "$work/wrong-key.yaml"
  mount_attempt "$LONGHORN_WRONG_KEY_ATTEMPT" "$LONGHORN_WRONG_KEY_SECRET" "$LONGHORN_DRY_RUN_SIZE_BYTES" "$LONGHORN_DRY_RUN_IMAGE" > "$work/wrong-key-attempt.yaml"
  mount_attempt "$LONGHORN_KEY_ATTEMPT" "$LONGHORN_KEY_SECRET" "$LONGHORN_DRY_RUN_SIZE_BYTES" "$LONGHORN_DRY_RUN_IMAGE" > "$work/key-attempt.yaml"
  for name in netpol cluster volume wrong-key wrong-key-attempt key-attempt; do
    echo "--- $name"
    cat "$work/$name.yaml"
    validate "$work/$name.yaml"
  done
}

seconds_since() {
  T="$1" yq -n '(now | to_unix) - (strenv(T) | to_unix)'
}

within_max_age() {
  local what="$1" age="$2"
  [ -n "$max_age_seconds" ] || return 0
  [ "$age" -le "$max_age_seconds" ] || fail "$what is ${age}s old, older than --max-age $max_age"
  echo "$what is ${age}s old, within --max-age $max_age"
}

require_fresh() {
  local what="$1" timestamp="$2" age
  [ -n "$max_age_seconds" ] || return 0
  age="$(seconds_since "$timestamp")" || fail "$what has no readable time: $timestamp"
  within_max_age "$what" "$age"
}

primary_pod() {
  local pod
  pod="$(kubectl get cluster.postgresql.cnpg.io "$1" -n "$POSTGRES_NAMESPACE" -o jsonpath='{.status.currentPrimary}')"
  [ -n "$pod" ] || fail "cluster $1 has no primary"
  echo "$pod"
}

pg_count() {
  local cluster="$1" database="$2" table="$3" pod
  pod="$(primary_pod "$cluster")"
  kubectl exec -n "$POSTGRES_NAMESPACE" "$pod" -c postgres -- psql -d "$database" -tAc "select count(*) from $table"
}

postgres_cleanup() {
  kubectl delete cluster.postgresql.cnpg.io "$POSTGRES_RESTORE_CLUSTER" -n "$POSTGRES_NAMESPACE" --ignore-not-found --wait
  kubectl delete pvc -n "$POSTGRES_NAMESPACE" -l "cnpg.io/cluster=$POSTGRES_RESTORE_CLUSTER" --ignore-not-found --wait
  kubectl delete networkpolicy "allow-${POSTGRES_RESTORE_CLUSTER}-egress" -n "$POSTGRES_NAMESPACE" --ignore-not-found
}

newest_base_backup_time() {
  kubectl get backups.postgresql.cnpg.io -n "$POSTGRES_NAMESPACE" -o json | C="$POSTGRES_SOURCE_CLUSTER" yq -p=json -r '
    .items[] | select(.spec.cluster.name == strenv(C) and .status.phase == "completed") | .status.stoppedAt' | sort | tail -n 1
}

test_postgres() {
  local check database table want got stopped
  if [ -n "$max_age_seconds" ]; then
    stopped="$(newest_base_backup_time)"
    [ -n "$stopped" ] || fail "cluster $POSTGRES_SOURCE_CLUSTER has no completed base backup"
    require_fresh "postgres: the newest base backup" "$stopped"
  fi
  echo "postgres: recovering $POSTGRES_RESTORE_CLUSTER from $POSTGRES_OBJECT_STORE"
  kubectl get cluster.postgresql.cnpg.io "$POSTGRES_RESTORE_CLUSTER" -n "$POSTGRES_NAMESPACE" >/dev/null 2>&1 \
    && fail "$POSTGRES_RESTORE_CLUSTER already exists; delete it first"
  cleanups+=(postgres_cleanup)
  restore_network_policy | kubectl apply -f -
  restore_cluster | kubectl apply -f -
  kubectl wait --for=condition=Ready "cluster.postgresql.cnpg.io/$POSTGRES_RESTORE_CLUSTER" \
    -n "$POSTGRES_NAMESPACE" --timeout="$POSTGRES_RESTORE_TIMEOUT" \
    || fail "$POSTGRES_RESTORE_CLUSTER did not become ready within $POSTGRES_RESTORE_TIMEOUT"
  for check in "${POSTGRES_CHECKS[@]}"; do
    read -r database table <<< "$check"
    want="$(pg_count "$POSTGRES_SOURCE_CLUSTER" "$database" "$table")"
    got="$(pg_count "$POSTGRES_RESTORE_CLUSTER" "$database" "$table")"
    [ "$want" = "$got" ] || fail "$database.$table has $got rows in the restore, $want in production"
    echo "postgres: $database.$table has $got rows in both"
  done
}

dump_key_time() {
  [[ "$1" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z\.gpg$ ]] || fail "dump key $1 holds no time"
  echo "${BASH_REMATCH[1]}T${BASH_REMATCH[2]}:${BASH_REMATCH[3]}:${BASH_REMATCH[4]}Z"
}

dumps_scratch() {
  kubectl exec -n "$POSTGRES_NAMESPACE" "$(primary_pod "$POSTGRES_SOURCE_CLUSTER")" -c postgres -- "$@"
}

dumps_cleanup() {
  dumps_scratch dropdb --if-exists "$DUMPS_SCRATCH_DATABASE"
  gpgconf --homedir "$DUMPS_GNUPGHOME" --kill all
}

dumps_credentials() {
  local encoded_id encoded_secret
  read -r encoded_id encoded_secret < <(kubectl get secret "$DUMPS_CREDENTIALS_SECRET" -n "$POSTGRES_NAMESPACE" \
    -o jsonpath='{.data.ACCESS_KEY_ID} {.data.ACCESS_SECRET_KEY}{"\n"}')
  AWS_ACCESS_KEY_ID="$(printf '%s' "$encoded_id" | base64 -d)"
  AWS_SECRET_ACCESS_KEY="$(printf '%s' "$encoded_secret" | base64 -d)"
  [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ] || fail "$POSTGRES_NAMESPACE/$DUMPS_CREDENTIALS_SECRET holds no R2 credential"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
}

test_dumps() {
  local account endpoint check database table key want got
  [ -d "$DUMPS_GNUPGHOME" ] || fail "$DUMPS_GNUPGHOME is not mounted; plug in the bedrock-keys stick"
  require_tools aws gpg gpgconf
  account="$(kubectl get configmap cluster-settings -n flux-system -o jsonpath='{.data.cloudflare_account_id}')"
  [ -n "$account" ] || fail "flux-system/cluster-settings holds no cloudflare_account_id"
  endpoint="https://$account.r2.cloudflarestorage.com"
  dumps_credentials
  export AWS_DEFAULT_REGION=auto
  export AWS_REQUEST_CHECKSUM_CALCULATION=when_required AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
  [ -z "$(dumps_scratch psql -tAc "select 1 from pg_database where datname = '$DUMPS_SCRATCH_DATABASE'")" ] \
    || fail "database $DUMPS_SCRATCH_DATABASE already exists; drop it first"
  cleanups+=(dumps_cleanup)
  for check in "${POSTGRES_CHECKS[@]}"; do
    read -r database table <<< "$check"
    key="$(aws s3 ls --endpoint-url "$endpoint" "s3://$DUMPS_BUCKET/$DUMPS_PREFIX/$database/" | awk '{ print $4 }' | sort | tail -n 1)"
    [ -n "$key" ] || fail "no dump of $database in s3://$DUMPS_BUCKET/$DUMPS_PREFIX/$database/"
    require_fresh "dumps: $key" "$(dump_key_time "$key")"
    key="$DUMPS_PREFIX/$database/$key"
    echo "dumps: restoring $key into $DUMPS_SCRATCH_DATABASE"
    dumps_scratch createdb "$DUMPS_SCRATCH_DATABASE"
    aws s3 cp --endpoint-url "$endpoint" "s3://$DUMPS_BUCKET/$key" - \
      | gpg --homedir "$DUMPS_GNUPGHOME" --decrypt \
      | kubectl exec -i -n "$POSTGRES_NAMESPACE" "$(primary_pod "$POSTGRES_SOURCE_CLUSTER")" -c postgres -- \
        pg_restore --no-owner --no-privileges --exit-on-error -d "$DUMPS_SCRATCH_DATABASE"
    want="$(pg_count "$POSTGRES_SOURCE_CLUSTER" "$database" "$table")"
    got="$(pg_count "$POSTGRES_SOURCE_CLUSTER" "$DUMPS_SCRATCH_DATABASE" "$table")"
    [ "$want" = "$got" ] || fail "$database.$table has $got rows in $key, $want in production"
    echo "dumps: $database.$table has $got rows in both"
    dumps_scratch dropdb "$DUMPS_SCRATCH_DATABASE"
  done
}

longhorn_field() {
  kubectl get volumes.longhorn.io "$LONGHORN_RESTORE_VOLUME" -n "$LONGHORN_NAMESPACE" -o jsonpath="{.status.$1}"
}

wait_until() {
  local timeout="$1" description="$2" waited=0
  shift 2
  until "$@"; do
    [ "$waited" -lt "$timeout" ] || fail "$description did not happen within ${timeout}s"
    sleep "$LONGHORN_POLL_SECONDS"
    waited=$((waited + LONGHORN_POLL_SECONDS))
  done
}

restore_finished() {
  [ "$(longhorn_field restoreInitiated)" = true ] && [ "$(longhorn_field restoreRequired)" = false ] \
    && [ "$(longhorn_field state)" = detached ]
}

restore_detached() {
  [ "$(longhorn_field state)" = detached ]
}

attempt_phase() {
  kubectl get pod "$1" -n "$LONGHORN_PVC_NAMESPACE" -o jsonpath='{.status.phase}'
}

attempt_failed_to_unlock() {
  local name="$1"
  case "$(attempt_phase "$name")" in
    Running | Succeeded) fail "pod $name mounted the restored volume with a wrong key" ;;
  esac
  kubectl get events -n "$LONGHORN_PVC_NAMESPACE" --field-selector "involvedObject.name=$name,reason=FailedMount" \
    -o jsonpath='{.items[*].message}' | grep -qi 'luksOpen\|passphrase'
}

attempt_finished() {
  case "$(attempt_phase "$1")" in
    Succeeded) return 0 ;;
    Failed) kubectl logs "$1" -n "$LONGHORN_PVC_NAMESPACE" >&2 || true; fail "pod $1 could not read the restored volume" ;;
    *) return 1 ;;
  esac
}

remove_attempt() {
  kubectl delete pod "$1" -n "$LONGHORN_PVC_NAMESPACE" --ignore-not-found --wait
  kubectl delete pvc "$1" -n "$LONGHORN_PVC_NAMESPACE" --ignore-not-found --wait
  kubectl delete pv "$1" --ignore-not-found --wait
}

longhorn_cleanup() {
  remove_attempt "$LONGHORN_WRONG_KEY_ATTEMPT"
  remove_attempt "$LONGHORN_KEY_ATTEMPT"
  kubectl delete secret "$LONGHORN_WRONG_KEY_SECRET" -n "$LONGHORN_NAMESPACE" --ignore-not-found
  kubectl delete volumes.longhorn.io "$LONGHORN_RESTORE_VOLUME" -n "$LONGHORN_NAMESPACE" --ignore-not-found --wait
}

test_longhorn() {
  local claim volume backup_url size encrypted created image
  claim="$(kubectl get deploy "$LONGHORN_DEPLOYMENT" -n "$LONGHORN_PVC_NAMESPACE" \
    -o jsonpath="{.spec.template.spec.volumes[?(@.name==\"$LONGHORN_DEPLOYMENT_VOLUME\")].persistentVolumeClaim.claimName}")"
  [ -n "$claim" ] || fail "deployment $LONGHORN_DEPLOYMENT mounts no claim as $LONGHORN_DEPLOYMENT_VOLUME"
  volume="$(kubectl get pvc "$claim" -n "$LONGHORN_PVC_NAMESPACE" -o jsonpath='{.spec.volumeName}')"
  [ -n "$volume" ] || fail "pvc $LONGHORN_PVC_NAMESPACE/$claim is not bound"
  read -r backup_url size encrypted created < <(kubectl get backups.longhorn.io -n "$LONGHORN_NAMESPACE" -o json \
    | VOLUME="$volume" yq -p=json -r '
        [.items[] | select(.status.volumeName == strenv(VOLUME) and .status.state == "Completed")]
        | sort_by(.status.backupCreatedAt) | (.[-1].status | .url + " " + .volumeSize + " " + (.labels["volume-encrypted"] // "disabled") + " " + .backupCreatedAt)')
  case "$backup_url" in null | "") fail "no completed backup of volume $volume" ;; esac
  [ "$encrypted" = enabled ] || fail "the newest backup of $claim ($volume) is not from an encrypted volume"
  require_fresh "longhorn: the newest backup of $claim" "$created"
  kubectl get volumes.longhorn.io "$LONGHORN_RESTORE_VOLUME" -n "$LONGHORN_NAMESPACE" >/dev/null 2>&1 \
    && fail "volume $LONGHORN_RESTORE_VOLUME already exists; delete it first"
  image="$(kubectl get deploy "$LONGHORN_DEPLOYMENT" -n "$LONGHORN_PVC_NAMESPACE" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "longhorn: restoring $backup_url of $claim into $LONGHORN_RESTORE_VOLUME"
  cleanups+=(longhorn_cleanup)
  longhorn_volume "$backup_url" "$size" | kubectl apply -f -
  wait_until "$LONGHORN_RESTORE_TIMEOUT_SECONDS" "restore of $backup_url" restore_finished
  [ "$(longhorn_field robustness)" != faulted ] || fail "restored volume is faulted"
  echo "longhorn: restore of $backup_url completed"

  wrong_key_secret | kubectl apply -f -
  mount_attempt "$LONGHORN_WRONG_KEY_ATTEMPT" "$LONGHORN_WRONG_KEY_SECRET" "$size" "$image" | kubectl apply -f -
  wait_until "$LONGHORN_MOUNT_TIMEOUT_SECONDS" "a LUKS unlock failure with a wrong key" attempt_failed_to_unlock "$LONGHORN_WRONG_KEY_ATTEMPT"
  echo "longhorn: the restored volume refuses to unlock with a wrong key"
  remove_attempt "$LONGHORN_WRONG_KEY_ATTEMPT"
  wait_until "$LONGHORN_MOUNT_TIMEOUT_SECONDS" "detach of $LONGHORN_RESTORE_VOLUME" restore_detached

  mount_attempt "$LONGHORN_KEY_ATTEMPT" "$LONGHORN_KEY_SECRET" "$size" "$image" | kubectl apply -f -
  wait_until "$LONGHORN_MOUNT_TIMEOUT_SECONDS" "a read of the restored volume with the key" attempt_finished "$LONGHORN_KEY_ATTEMPT"
  echo "longhorn: the restored volume unlocks with $LONGHORN_KEY_SECRET and lists $(kubectl logs "$LONGHORN_KEY_ATTEMPT" -n "$LONGHORN_PVC_NAMESPACE")"
}

test_etcd() {
  local newest name created age
  newest="$(kubectl get etcdsnapshotfiles.k3s.cattle.io -o json | B="$ETCD_S3_BUCKET" P="$ETCD_S3_PREFIX" yq -p=json -r '
    [.items[] | select(.spec.s3.bucket == strenv(B) and .spec.s3.prefix == strenv(P) and .status.readyToUse == true)]
    | sort_by(.status.creationTime) | .[-1] | .metadata.name + " " + .status.creationTime')" || newest=""
  case "$newest" in null* | "") fail "no ready snapshot in s3://$ETCD_S3_BUCKET/$ETCD_S3_PREFIX" ;; esac
  name="${newest% *}"
  created="${newest#* }"
  age="$(seconds_since "$created")" || fail "etcd snapshot $name has no readable creation time"
  [ "$age" -le "$ETCD_MAX_AGE_SECONDS" ] || fail "newest etcd snapshot $name is ${age}s old, limit ${ETCD_MAX_AGE_SECONDS}s"
  echo "etcd: newest snapshot $name is ${age}s old"
  within_max_age "etcd: snapshot $name" "$age"
}

if $dry_run; then
  dry_run_manifests
  exit 0
fi

case "$command" in
  postgres) test_postgres ;;
  longhorn) test_longhorn ;;
  etcd) test_etcd ;;
  dumps) test_dumps ;;
  all) test_etcd; test_longhorn; test_postgres; test_dumps ;;
esac
echo "restore test passed: $command"

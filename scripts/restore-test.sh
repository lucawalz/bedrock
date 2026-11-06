#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

usage="usage: restore-test.sh [--dry-run] postgres|longhorn|etcd|all"

POSTGRES_NAMESPACE=postgres
POSTGRES_SOURCE_CLUSTER=postgres
POSTGRES_RESTORE_CLUSTER=postgres-restore-test
POSTGRES_OBJECT_STORE=postgres-backup
POSTGRES_RESTORE_TIMEOUT=30m
# Migration history only changes on upgrades, so recent writes lost to WAL recovery cannot cause a mismatch.
POSTGRES_CHECKS=("pocket-id schema_migrations" "paperless django_migrations")

LONGHORN_NAMESPACE=longhorn-system
LONGHORN_PVC_NAMESPACE=paperless
LONGHORN_PVC=paperless-ngx-data
LONGHORN_RESTORE_VOLUME=restore-test
LONGHORN_RESTORE_TIMEOUT_SECONDS=1800
LONGHORN_POLL_SECONDS=10

ETCD_S3_BUCKET=bedrock-etcd
ETCD_S3_PREFIX=etcd-snapshots
ETCD_MAX_AGE_SECONDS=$((13 * 3600))

API_SERVER_CIDRS=(10.20.0.10/32 10.20.0.11/32 10.20.0.12/32)
PRIVATE_CIDRS=(10.42.0.0/16 10.43.0.0/16 10.20.0.0/24 10.30.0.0/24 192.168.2.0/24)

dry_run=false
command=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry_run=true ;;
    postgres | longhorn | etcd | all) command="$arg" ;;
    *) echo "$usage" >&2; exit 2 ;;
  esac
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

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

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
          serverName: ${POSTGRES_SOURCE_CLUSTER}
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
  longhorn_volume "s3://example@auto/?backup=backup-0&volume=pvc-0" 5368709120 > "$work/volume.yaml"
  for name in netpol cluster volume; do
    echo "--- $name"
    cat "$work/$name.yaml"
    validate "$work/$name.yaml"
  done
}

pg_count() {
  local cluster="$1" database="$2" table="$3" pod
  pod="$(kubectl get cluster.postgresql.cnpg.io "$cluster" -n "$POSTGRES_NAMESPACE" -o jsonpath='{.status.currentPrimary}')"
  [ -n "$pod" ] || fail "cluster $cluster has no primary"
  kubectl exec -n "$POSTGRES_NAMESPACE" "$pod" -c postgres -- psql -d "$database" -tAc "select count(*) from $table"
}

postgres_cleanup() {
  kubectl delete cluster.postgresql.cnpg.io "$POSTGRES_RESTORE_CLUSTER" -n "$POSTGRES_NAMESPACE" --ignore-not-found --wait
  kubectl delete pvc -n "$POSTGRES_NAMESPACE" -l "cnpg.io/cluster=$POSTGRES_RESTORE_CLUSTER" --ignore-not-found --wait
  kubectl delete networkpolicy "allow-${POSTGRES_RESTORE_CLUSTER}-egress" -n "$POSTGRES_NAMESPACE" --ignore-not-found
}

test_postgres() {
  local check database table want got
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

longhorn_field() {
  kubectl get volumes.longhorn.io "$LONGHORN_RESTORE_VOLUME" -n "$LONGHORN_NAMESPACE" -o jsonpath="{.status.$1}"
}

longhorn_cleanup() {
  kubectl delete volumes.longhorn.io "$LONGHORN_RESTORE_VOLUME" -n "$LONGHORN_NAMESPACE" --ignore-not-found --wait
}

test_longhorn() {
  local volume backup_url size waited=0
  volume="$(kubectl get pvc "$LONGHORN_PVC" -n "$LONGHORN_PVC_NAMESPACE" -o jsonpath='{.spec.volumeName}')"
  [ -n "$volume" ] || fail "pvc $LONGHORN_PVC_NAMESPACE/$LONGHORN_PVC is not bound"
  read -r backup_url size < <(kubectl get backups.longhorn.io -n "$LONGHORN_NAMESPACE" -o json \
    | VOLUME="$volume" yq -p=json -r '
        [.items[] | select(.status.volumeName == strenv(VOLUME) and .status.state == "Completed")]
        | sort_by(.status.backupCreatedAt) | (.[-1].status | .url + " " + .volumeSize)')
  case "$backup_url" in null | "") fail "no completed backup of volume $volume" ;; esac
  kubectl get volumes.longhorn.io "$LONGHORN_RESTORE_VOLUME" -n "$LONGHORN_NAMESPACE" >/dev/null 2>&1 \
    && fail "volume $LONGHORN_RESTORE_VOLUME already exists; delete it first"
  echo "longhorn: restoring $backup_url into $LONGHORN_RESTORE_VOLUME"
  cleanups+=(longhorn_cleanup)
  longhorn_volume "$backup_url" "$size" | kubectl apply -f -
  while ! { [ "$(longhorn_field restoreInitiated)" = true ] && [ "$(longhorn_field restoreRequired)" = false ] \
    && [ "$(longhorn_field state)" = detached ]; }; do
    [ "$waited" -lt "$LONGHORN_RESTORE_TIMEOUT_SECONDS" ] || fail "restore of $backup_url did not finish within ${LONGHORN_RESTORE_TIMEOUT_SECONDS}s"
    sleep "$LONGHORN_POLL_SECONDS"
    waited=$((waited + LONGHORN_POLL_SECONDS))
  done
  [ "$(longhorn_field robustness)" != faulted ] || fail "restored volume is faulted"
  echo "longhorn: restore of $backup_url completed"
}

test_etcd() {
  local newest age
  newest="$(kubectl get etcdsnapshotfiles.k3s.cattle.io -o json | B="$ETCD_S3_BUCKET" P="$ETCD_S3_PREFIX" yq -p=json -r '
    [.items[] | select(.spec.s3.bucket == strenv(B) and .spec.s3.prefix == strenv(P) and .status.readyToUse == true)]
    | sort_by(.status.creationTime) | .[-1] | .metadata.name + " " + (((now | to_unix) - (.status.creationTime | to_unix)) | tostring)')" || newest=""
  case "$newest" in null* | "") fail "no ready snapshot in s3://$ETCD_S3_BUCKET/$ETCD_S3_PREFIX" ;; esac
  age="${newest#* }"
  [ "$age" -le "$ETCD_MAX_AGE_SECONDS" ] || fail "newest etcd snapshot ${newest% *} is ${age}s old, limit ${ETCD_MAX_AGE_SECONDS}s"
  echo "etcd: newest snapshot ${newest% *} is ${age}s old"
}

if $dry_run; then
  dry_run_manifests
  exit 0
fi

case "$command" in
  postgres) test_postgres ;;
  longhorn) test_longhorn ;;
  etcd) test_etcd ;;
  all) test_etcd; test_longhorn; test_postgres ;;
esac
echo "restore test passed: $command"

#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools kubeconform yq kustomize

k8s_dir=kubernetes
kubernetes_version="${KUBECONFORM_KUBERNETES_VERSION:-1.35.0}"
derived_schemas="${1:-}"
rendered_releases="${2:-}"

cluster_secret_readers=(
  cert-manager/cert-manager
  cert-manager/cert-manager-cainjector
  cnpg-system/cloudnative-pg
  cnpg-system/plugin-barman-cloud
  flux-system/flux-operator
  longhorn-system/longhorn-service-account
  longhorn-system/longhorn-support-bundle
  monitoring/kube-prometheus-stack-operator
)
protected_secret_namespaces=(flux-system longhorn-system postgres)
pg_hba_dumper="hostssl all dumper all scram-sha-256"
pg_hba_sameuser="hostssl sameuser all all scram-sha-256"
pg_hba_reject="host all all all reject"
digest_exempt_images=(docker.io/longhornio/longhorn-share-manager)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

find "$k8s_dir" -name kustomization.yaml | sort > "$work/kustomizations"

# A kustomize patch is a fragment of a resource, so it never satisfies that resource's schema.
: > "$work/patches"
while IFS= read -r kustomization; do
  directory="$(dirname "$kustomization")"
  while IFS= read -r patch; do
    [ -n "$patch" ] || continue
    printf '%s/%s\n' "$(cd "$directory" && cd "$(dirname "$patch")" && pwd)" "$(basename "$patch")" >> "$work/patches"
  done < <(yq -N '.patches[]?.path // ""' "$kustomization" </dev/null)
done < "$work/kustomizations"
sort -u -o "$work/patches" "$work/patches"

find "$k8s_dir" -name '*.yaml' \
  ! -path "*/flux-system/gotk-components.yaml" \
  ! -name '*.sops.yaml' \
  | sort > "$work/candidates"

: > "$work/manifests"
while IFS= read -r file; do
  grep -qxF "$PWD/$file" "$work/patches" && continue
  # Collected rather than piped into grep, so a short-circuiting reader cannot SIGPIPE yq mid-file.
  declares_kind="$(yq -N 'has("kind")' "$file" </dev/null)"
  case "$declares_kind" in
    # Helm values and kustomize configuration live beside manifests and declare no resource.
    *true*) printf '%s\n' "$file" >> "$work/manifests" ;;
  esac
done < "$work/candidates"

schema_locations=(-schema-location default)
if [ -n "$derived_schemas" ]; then
  schema_locations+=(-schema-location "$derived_schemas/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json")
fi
if [ -n "${KUBECONFORM_SCHEMA_LOCATION:-}" ]; then
  schema_locations+=(-schema-location "$KUBECONFORM_SCHEMA_LOCATION")
fi

skipped="$(comm -23 "$work/candidates" "$work/manifests")"
if [ -n "$skipped" ]; then
  echo "Not manifests, skipped:"
  printf '%s\n' "$skipped" | sed 's/^/  /'
fi

status=0
xargs -a "$work/manifests" kubeconform \
  -strict \
  -ignore-missing-schemas \
  "${schema_locations[@]}" \
  -kubernetes-version "$kubernetes_version" \
  -summary || status=1

if [ -z "$rendered_releases" ]; then
  rendered_releases="$work/rendered"
  if ! RENDER_OUTPUT_DIR="$rendered_releases" scripts/render-helm-releases.sh > "$work/render.log" 2>&1; then
    cat "$work/render.log" >&2
    echo "render-helm-releases.sh failed, so cluster-wide Secret readers cannot be resolved" >&2
    exit 1
  fi
fi

grep -rl "kustomize.toolkit.fluxcd.io" "$k8s_dir" --include="*.yaml" \
  | xargs yq -N 'select(.kind == "Kustomization" and .apiVersion == "kustomize.toolkit.fluxcd.io/v1") | .spec.path' \
  | grep "^\./$k8s_dir/" | sort -u > "$work/flux-paths"
: > "$work/built.yaml"
while IFS= read -r path; do
  printf -- '---\n' >> "$work/built.yaml"
  kustomize build "$path" >> "$work/built.yaml"
done < "$work/flux-paths"
for release in "$rendered_releases"/*.yaml; do
  printf -- '---\n' >> "$work/built.yaml"
  cat "$release" >> "$work/built.yaml"
done

# yq treats a bare "*" in == as a glob, so wildcards are matched with test().
# shellcheck disable=SC2016
PROTECTED="${protected_secret_namespaces[*]}" yq ea -N '
  [.] as $documents
  | (strenv(PROTECTED) | split(" ")) as $protected
  | ($documents | map(select((.kind == "ClusterRole" or .kind == "Role") and (
      .rules // [] | any_c(
        ((.apiGroups // [""]) | any_c(test("^(|\\*)$")))
        and ((.resources // []) | any_c(test("^(secrets|\\*)$")))
        and ((.verbs // []) | any_c(test("^(get|list|watch|\\*)$")))
      )
    )))) as $direct
  | ($direct | map(select(.kind == "ClusterRole"))) as $directCluster
  | ($documents | map(select(.kind == "ClusterRole" and .aggregationRule) | select(
      .aggregationRule.clusterRoleSelectors // [] | any_c(.matchLabels as $wanted
        | $directCluster | any_c(.metadata.labels as $labels
          | $wanted | to_entries | all_c($labels[.key] == .value)))))) as $aggregated
  | (($directCluster + $aggregated | map(.metadata.name)) + ["cluster-admin", "admin", "edit"]) as $readers
  | ($direct | map(select(.kind == "Role") | .metadata.namespace + "/" + .metadata.name)) as $roleReaders
  | $documents[] as $binding
  | $binding
  | select(.kind == "ClusterRoleBinding" or (.kind == "RoleBinding" and (.metadata.namespace as $ns | $protected | any_c(. == $ns))))
  | (if .kind == "ClusterRoleBinding" then "every namespace" else .metadata.namespace end) as $scope
  | select(
      (.roleRef.kind == "ClusterRole" and (.roleRef.name as $role | $readers | any_c(. == $role)))
      or (.roleRef.kind == "Role" and ((.metadata.namespace + "/" + .roleRef.name) as $role | $roleReaders | any_c(. == $role))))
  | .subjects[]?
  | (.namespace // .kind) + "/" + .name + "\t" + $scope
' "$work/built.yaml" | sort -u > "$work/secret-readers"
printf '%s\n' "${cluster_secret_readers[@]}" | sort -u > "$work/allowed-secret-readers"

unexpected="$(awk -F'\t' 'NR == FNR { allowed[$1] = 1; next } !($1 in allowed) { print "  - " $1 " in " $2 }' \
  "$work/allowed-secret-readers" "$work/secret-readers")"
if [ -n "$unexpected" ]; then
  echo "Subjects outside the allowlist can read Secrets:"
  printf '%s\n' "$unexpected"
  status=1
fi

baseline_network_policies=(default-deny allow-dns)
builtin_namespaces=(default kube-node-lease kube-public kube-system)
baseline_exempt_namespaces=(kube-system)

{
  yq -N 'select(.kind == "Namespace") | .metadata.name' "$work/built.yaml"
  printf '%s\n' "${builtin_namespaces[@]}"
} | sort -u > "$work/namespaces"

yq -N 'select(.kind == "ConfigMap" and .metadata.namespace == "kyverno" and .metadata.name == "kyverno") | .data.resourceFilters' "$work/built.yaml" \
  | grep -o '\[[^]]*\]' \
  | awk -F'[][,]' '($2 == "*/*" || $2 == "*") && $4 == "*" { print $3 }' \
  | sort -u > "$work/filtered-namespaces"

yq -N 'select(.kind == "ClusterPolicy") | .spec.rules[] | select(.generate.kind == "NetworkPolicy")
  | .generate.name + " " + ([.preconditions.all[]? | select(.key == "{{request.object.metadata.name}}" and .operator == "AnyNotIn") | .value[]] | join(","))' \
  "$work/built.yaml" > "$work/generated-network-policies"

yq -N 'select(.kind == "NetworkPolicy") | .metadata.namespace + "/" + .metadata.name' "$work/built.yaml" \
  | sort -u > "$work/declared-network-policies"

while read -r generated excluded; do
  if [ "$(tr ',' '\n' <<< "$excluded" | sort -u)" != "$(cat "$work/filtered-namespaces")" ]; then
    echo "generate rule $generated excludes [$excluded], not the Kyverno resource-filter namespaces [$(paste -sd, "$work/filtered-namespaces")]"
    status=1
  fi
done < "$work/generated-network-policies"

generated_in() {
  local namespace="$1" name="$2" generated excluded
  while read -r generated excluded; do
    [ "$generated" = "$name" ] || continue
    [[ ",$excluded," == *",$namespace,"* ]] || return 0
  done < "$work/generated-network-policies"
  return 1
}

uncovered=""
while read -r namespace; do
  [[ " ${baseline_exempt_namespaces[*]} " == *" $namespace "* ]] && continue
  for name in "${baseline_network_policies[@]}"; do
    grep -qxF "$namespace/$name" "$work/declared-network-policies" && continue
    generated_in "$namespace" "$name" && continue
    uncovered+="  - $name in $namespace"$'\n'
  done
done < "$work/namespaces"
if [ -n "$uncovered" ]; then
  echo "Namespaces neither generated nor declared with a baseline NetworkPolicy:"
  printf '%s' "$uncovered"
  status=1
fi

# shellcheck disable=SC2016
open_postgres="$(DUMPER="$pg_hba_dumper" SAMEUSER="$pg_hba_sameuser" REJECT="$pg_hba_reject" yq -N '
  select(.kind == "Cluster" and .apiVersion == "postgresql.cnpg.io/*")
  | (.spec.postgresql.pg_hba // []) as $hba
  | (if ($hba[0] // "") == strenv(DUMPER) then 1 else 0 end) as $sameuser_index
  | select(.spec.enableSuperuserAccess != false
    or ($hba[$sameuser_index] // "") != strenv(SAMEUSER)
    or ($hba[-1] // "") != strenv(REJECT))
  | .metadata.namespace + "/" + .metadata.name' "$work/built.yaml")"
if [ -n "$open_postgres" ]; then
  echo "CNPG Clusters that allow superuser access or whose pg_hba does not start with '$pg_hba_sameuser', optionally preceded by '$pg_hba_dumper', and end with '$pg_hba_reject':"
  printf '%s\n' "$open_postgres" | sed 's/^/  - /'
  status=1
fi

# shellcheck disable=SC2016
unsafe_storage="$(yq ea -N '
  [.] as $documents
  | ($documents | map(select(.kind == "StorageClass" and .parameters.numberOfReplicas == "1") | .metadata.name)) as $single
  | $documents[]
  | select(.kind == "Cluster" and .apiVersion == "postgresql.cnpg.io/*")
  | select(.spec.storage.storageClass as $class | $single | any_c(. == $class) | not)
  | .metadata.namespace + "/" + .metadata.name + " (storageClass: " + (.spec.storage.storageClass // "unset") + ")"
' "$work/built.yaml")"
if [ -n "$unsafe_storage" ]; then
  echo "CNPG Clusters whose storageClass is not a declared StorageClass with numberOfReplicas \"1\":"
  printf '%s\n' "$unsafe_storage" | sed 's/^/  - /'
  status=1
fi

# shellcheck disable=SC2016
yq -N '
  select(.kind == "Deployment" or .kind == "StatefulSet" or .kind == "DaemonSet" or .kind == "Job" or .kind == "CronJob" or .kind == "Pod")
  | (.spec.jobTemplate.spec.template.spec // .spec.template.spec // .spec) as $pod
  | (($pod.initContainers // []) + ($pod.containers // []))[]
  | .image
' "$work/built.yaml" > "$work/workload-images"
yq -N 'select(.apiVersion == "monitoring.coreos.com/*" and .spec.image != null) | .spec.image' "$work/built.yaml" >> "$work/workload-images"
unpinned="$(grep -v '@sha256:[0-9a-f]\{64\}$' "$work/workload-images" \
  | grep -vE "^($(IFS="|"; echo "${digest_exempt_images[*]//./\\.}")):" \
  | sort -u || true)"
if [ -n "$unpinned" ]; then
  echo "Workload images without an @sha256 digest (pin it in values, or list it in digest_exempt_images and ADR 0014):"
  printf '%s\n' "$unpinned" | sed 's/^/  - /'
  status=1
fi

# shellcheck disable=SC2016
stale_versions="$(yq -N '
  select(.apiVersion == "monitoring.coreos.com/*" and .spec.image != null and .spec.version != null)
  | .spec.version as $version
  | select(.spec.image | sub("@sha256:.*$", "") | sub("^.*:", "") | test("^" + $version) | not)
  | .kind + " " + .metadata.namespace + "/" + .metadata.name + ": version " + .spec.version + ", image " + .spec.image
' "$work/built.yaml")"
if [ -n "$stale_versions" ]; then
  echo "Prometheus Operator resources whose version does not match their image tag:"
  printf '%s\n' "$stale_versions" | sed 's/^/  - /'
  status=1
fi

exit "$status"

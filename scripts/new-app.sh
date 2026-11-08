#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools yq kustomize

usage="usage: new-app.sh <name> <host> <port> [db=true|false] [sso=true|false] [image=<repository>:<tag>]"
apps_dir=kubernetes/apps
index="$apps_dir/kustomization.yaml"
traefik_release=kubernetes/infrastructure/controllers/onprem/traefik/helmrelease.yaml
reloader_release=kubernetes/infrastructure/controllers/security/reloader/helmrelease.yaml
cluster_domain="$(yq -N '.data.cluster_domain' kubernetes/clusters/home/config/cluster-settings.yaml)"
chart_version="5.3.0"
placeholder_registry=registry.invalid
placeholder_tag=0.0.0
max_name_length=40
max_port=65535

fail() {
  echo "$*" >&2
  exit 1
}

# accepts both "db=true" and "true", so `just new-app demo host 8080 db=true` reads naturally
value_of() {
  local key="$1" raw="$2"
  printf '%s' "${raw#"$key"=}"
}

boolean() {
  case "$2" in
    true | false) printf '%s' "$2" ;;
    *) fail "$1 must be true or false, got '$2'" ;;
  esac
}

[ "$#" -ge 3 ] && [ "$#" -le 6 ] || fail "$usage"

name="$1"
host="$2"
port="$3"
db="$(boolean db "$(value_of db "${4:-false}")")"
sso="$(boolean sso "$(value_of sso "${5:-false}")")"
image="$(value_of image "${6:-}")"

[[ "$name" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]] && [ "${#name}" -le "$max_name_length" ] \
  || fail "name must be a lowercase DNS label of at most $max_name_length characters, got '$name'"
[[ "$host" =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || fail "host must be a lowercase hostname, got '$host'"
[[ "$port" =~ ^[1-9][0-9]*$ ]] && [ "$port" -le "$max_port" ] || fail "port must be 1-$max_port, got '$port'"
[ ! -e "$apps_dir/$name" ] || fail "$apps_dir/$name already exists"
yq -e ".resources[] | select(. == \"$name\")" "$index" >/dev/null 2>&1 && fail "$index already lists $name"

case "$host" in
  *".$cluster_domain") route_host="${host%".$cluster_domain"}.\${cluster_domain}" ;;
  *) route_host="$host" ;;
esac

if [ -z "$image" ]; then
  image_repository="$placeholder_registry/$name"
  image_tag="$placeholder_tag"
else
  [[ "$image" =~ ^([^@]+/[^:@/]+):([^:@/]+)$ ]] || fail "image must be <repository>:<tag>, got '$image'"
  image_repository="${BASH_REMATCH[1]}"
  image_tag="${BASH_REMATCH[2]}"
  [ "$image_tag" != latest ] || fail "image tag latest is rejected by the disallow-latest-tag policy"
fi

app="$apps_dir/$name"
mkdir -p "$app/app"

postgres_label=""
db_kustomization=""
db_dependency=""
env_from=""
postgres_egress=""
sso_component=""
sso_middleware=""

if [ "$db" = true ]; then
  postgres_label='    bedrock.io/postgres-client: "true"'$'\n'
  db_dependency="    - name: $name-db"$'\n'
  env_from="            envFrom:
              - secretRef:
                  name: $name
"
  postgres_egress="---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-$name-egress-postgres
  namespace: $name
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: $name
  policyTypes:
    - Egress
  egress:
    - to:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: postgres
          podSelector:
            matchLabels:
              cnpg.io/cluster: postgres
      ports:
        - protocol: TCP
          port: 5432
"
  db_kustomization="apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: $name-db
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  path: ./$app/db
  targetNamespace: postgres
  prune: true
  wait: true
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: cluster-cnpg-db
  # no failed expression: a Database reports applied false until its owner role exists, which is transient here
  healthCheckExprs:
    - apiVersion: postgresql.cnpg.io/v1
      kind: DatabaseRole
      current: has(status.applied) && status.applied && status.observedGeneration == metadata.generation
    - apiVersion: postgresql.cnpg.io/v1
      kind: Database
      current: has(status.applied) && status.applied && status.observedGeneration == metadata.generation
---
"
fi

if [ "$sso" = true ]; then
  sso_component="  - ../../../components/forward-auth"$'\n'
  sso_middleware="      middlewares:
        - name: forward-auth
"
fi

cat > "$app/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - namespace.yaml
  - ks.yaml
EOF

cat > "$app/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $name
  annotations:
    kustomize.toolkit.fluxcd.io/prune: disabled
  labels:
${postgres_label}    bedrock.io/traefik-routable: "true"
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/warn: baseline
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: default
  namespace: $name
automountServiceAccountToken: false
EOF

cat > "$app/ks.yaml" <<EOF
${db_kustomization}apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: $name
  namespace: flux-system
spec:
  interval: 10m
  retryInterval: 1m
  path: ./$app/app
  prune: true
  wait: true
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: flux-system
  dependsOn:
    - name: cluster-edge-onprem
${db_dependency}  postBuild:
    substituteFrom:
      - kind: ConfigMap
        name: cluster-settings
---
apiVersion: notification.toolkit.fluxcd.io/v1
kind: Alert
metadata:
  name: $name-flux
  namespace: flux-system
spec:
  providerRef:
    name: ntfy
  eventSeverity: error
  eventSources:
    - kind: HelmRelease
      name: '*'
      namespace: $name
EOF

cat > "$app/app/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: $name
components:
  - ../../../components/network-policies/base
${sso_component}  - ../../../components/topology-spread
resources:
  - helmrelease.yaml
  - ingress.yaml
  - networkpolicies.yaml
EOF

cat > "$app/app/helmrelease.yaml" <<EOF
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: $name
  namespace: $name
spec:
  interval: 30m
  timeout: 10m
  chart:
    spec:
      chart: app-template
      version: "$chart_version"
      sourceRef:
        kind: HelmRepository
        name: bjw-s
        namespace: flux-system
  install:
    strategy:
      name: RetryOnFailure
  upgrade:
    force: true
    strategy:
      name: RetryOnFailure
  driftDetection:
    mode: warn
  values:
    controllers:
      $name:
        strategy: RollingUpdate
        annotations:
          reloader.stakater.com/auto: "true"
        containers:
          app:
            image:
              repository: $image_repository
              tag: "$image_tag"
${env_from}            probes:
              liveness:
                enabled: true
                custom: true
                spec:
                  tcpSocket:
                    port: $port
                  periodSeconds: 15
              readiness:
                enabled: true
                custom: true
                spec:
                  tcpSocket:
                    port: $port
                  periodSeconds: 10
              startup:
                enabled: false
            resources:
              requests:
                cpu: 10m
                memory: 64Mi
              limits:
                memory: 256Mi
            securityContext:
              allowPrivilegeEscalation: false
              readOnlyRootFilesystem: true
              capabilities:
                drop:
                  - ALL
    defaultPodOptions:
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        runAsGroup: 1000
        fsGroup: 1000
        seccompProfile:
          type: RuntimeDefault
    service:
      app:
        controller: $name
        ports:
          http:
            port: $port
    persistence:
      tmp:
        type: emptyDir
        globalMounts:
          - path: /tmp
EOF

cat > "$app/app/ingress.yaml" <<EOF
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: $name
  namespace: $name
  annotations:
    gethomepage.dev/enabled: "true"
    gethomepage.dev/name: $name
    gethomepage.dev/group: Apps
    gethomepage.dev/href: https://$route_host
    gethomepage.dev/podSelector: app.kubernetes.io/name=$name
    gethomepage.dev/statusStyle: "dot"
spec:
  entryPoints:
    - websecure
  routes:
    - match: Host(\`$route_host\`)
      kind: Rule
${sso_middleware}      services:
        - name: $name
          port: $port
  tls: {}
EOF

cat > "$app/app/networkpolicies.yaml" <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-$name-ingress
  namespace: $name
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: $name
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: traefik
      ports:
        - protocol: TCP
          port: $port
EOF
printf '%s' "$postgres_egress" >> "$app/app/networkpolicies.yaml"

if [ "$db" = true ]; then
  mkdir -p "$app/db"
  cat > "$app/db/kustomization.yaml" <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: postgres
resources:
  - databaserole.yaml
  - database.yaml
EOF
  cat > "$app/db/databaserole.yaml" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: DatabaseRole
metadata:
  name: $name
spec:
  name: $name
  cluster:
    name: postgres
  login: true
  passwordSecret:
    name: pg-$name
EOF
  cat > "$app/db/database.yaml" <<EOF
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: $name
spec:
  name: $name
  owner: $name
  cluster:
    name: postgres
EOF
fi

NAME="$name" yq -i '.resources += [strenv(NAME)]' "$index"
NAME="$name" yq -i '
  .spec.values.providers.kubernetesCRD.namespaces += [strenv(NAME)]
  | .spec.values.providers.kubernetesIngress.namespaces += [strenv(NAME)]
' "$traefik_release"
NAME="$name" yq -i '.spec.values.reloader.namespaces += [strenv(NAME)]' "$reloader_release"
bash scripts/gen-inventory.sh

# resolves alert selectors against live Prometheus, which a new app neither changes nor can satisfy offline
live_only_check=scripts/check-alert-selectors.sh
checks=(scripts/check-*.sh scripts/render-helm-releases.sh scripts/validate-substitution.sh scripts/apply-policies.sh)
failed=()
for dir in "$app" "$app/app" "$app/db"; do
  [ -d "$dir" ] || continue
  kustomize build "$dir" >/dev/null || failed+=("kustomize build $dir")
done
for check in "${checks[@]}"; do
  [ "$check" != "$live_only_check" ] || continue
  echo "Running $check"
  bash "$check" >/dev/null 2>&1 || failed+=("$check")
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "Scaffolded $app, but these checks failed; rerun them for detail:" >&2
  printf '  - %s\n' "${failed[@]}" >&2
  exit 1
fi

echo
echo "Scaffolded $app and every check passed."
echo "Next steps:"
if [ -z "$image" ]; then
  echo "  - Set the image in $app/app/helmrelease.yaml; $image_repository:$image_tag is a placeholder."
fi
echo "  - Adjust the probes, resources, runAsUser and writable paths in $app/app/helmrelease.yaml to the image."
if [ "$db" = true ]; then
  echo "  - In bedrock-secrets, add clusters/home/apps/pg-$name.sops.yaml: a kubernetes.io/basic-auth Secret pg-$name in"
  echo "    namespace postgres, labelled cnpg.io/reload: \"true\", with username $name and a random password."
  echo "  - In bedrock-secrets, add clusters/home/apps/$name.sops.yaml: a Secret $name in namespace $name whose keys"
  echo "    become the container environment, for example DATABASE_URL pointing at postgres-rw.postgres.svc.cluster.local:5432/$name."
  echo "  - List both in clusters/home/apps/kustomization.yaml there. just new-secret $name does all of this with random values."
  echo "  - Commit bedrock-secrets."
fi
echo "  - Commit $app, $index, $traefik_release, $reloader_release and docs/inventory.md."

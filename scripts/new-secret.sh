#!/usr/bin/env bash
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

require_tools sops yq od

[ "$#" -eq 1 ] || { echo "usage: new-secret.sh <app>" >&2; exit 1; }

name="$1"
secrets_repo="${BEDROCK_SECRETS:-$repo_root/../bedrock-secrets}"
apps_secrets=clusters/home/apps
postgres_host=postgres-rw.postgres.svc.cluster.local
postgres_port=5432
random_bytes=32

[[ "$name" =~ ^[a-z]([a-z0-9-]*[a-z0-9])?$ ]] || { echo "name must be a lowercase DNS label, got '$name'" >&2; exit 1; }
[ -f "$secrets_repo/.sops.yaml" ] || { echo "$secrets_repo holds no .sops.yaml; set BEDROCK_SECRETS" >&2; exit 1; }
cd "$secrets_repo"

role_file="$apps_secrets/pg-$name.sops.yaml"
app_file="$apps_secrets/$name.sops.yaml"
for file in "$role_file" "$app_file"; do
  [ ! -e "$file" ] || { echo "$secrets_repo/$file already exists" >&2; exit 1; }
done

random_hex() {
  od -An -tx1 -N"$random_bytes" /dev/urandom | tr -d ' \n'
}

set_value() {
  local file="$1" key="$2" value="$3"
  printf '"%s"' "$value" | sops set --value-stdin "$file" "[\"stringData\"][\"$key\"]"
}

cat > "$role_file" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: pg-$name
  namespace: postgres
  labels:
    cnpg.io/reload: "true"
type: kubernetes.io/basic-auth
stringData: {}
EOF

cat > "$app_file" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: $name
  namespace: $name
type: Opaque
stringData: {}
EOF

sops --encrypt --in-place "$role_file"
sops --encrypt --in-place "$app_file"

password="$(random_hex)"
set_value "$role_file" username "$name"
set_value "$role_file" password "$password"
set_value "$app_file" DATABASE_URL "postgresql://$name:$password@$postgres_host:$postgres_port/$name"
unset password

ROLE="pg-$name.sops.yaml" APP="$name.sops.yaml" yq -i '.resources += [strenv(ROLE), strenv(APP)]' "$apps_secrets/kustomization.yaml"

echo "Created $secrets_repo/$role_file and $secrets_repo/$app_file with random values, and listed both in $apps_secrets/kustomization.yaml."
echo "Add further app keys with: sops $secrets_repo/$app_file"
echo "Commit bedrock-secrets when done."

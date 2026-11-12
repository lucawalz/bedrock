set shell := ["bash", "-euo", "pipefail", "-c"]

apps_dir := "kubernetes/apps"
postgres_namespace := "postgres"
postgres_cluster := "postgres"
primary_selector := "cnpg.io/cluster=" + postgres_cluster + ",cnpg.io/instanceRole=primary"
backup_plugin := "barman-cloud.cloudnative-pg.io"
backup_timeout := "30m"
scale_down_timeout_seconds := "300"
poll_seconds := "2"
log_tail_lines := "100"
max_log_streams := "20"

default:
    @just --list

# Scaffold kubernetes/apps/<name> and run every check, for example: just new-app demo demo.syslabs.dev 8080 db=true sso=true
new-app name host port db="false" sso="false" image="":
    bash scripts/new-app.sh {{ quote(name) }} {{ quote(host) }} {{ quote(port) }} {{ quote(db) }} {{ quote(sso) }} {{ quote(image) }}

# Create encrypted pg-<app> and <app> secrets with random values in bedrock-secrets
new-secret app:
    bash scripts/new-secret.sh {{ quote(app) }}

# Copy a local folder of scans into the paperless consume folder, for example: just paperless-import ~/scans
paperless-import dir:
    bash scripts/paperless-import.sh {{ quote(join(invocation_directory(), dir)) }}

# Show an app's admin login and copy its password, for example: just login grafana; add show=true to print it
login app show="false":
    bash scripts/login.sh {{ quote(app) }} {{ quote(show) }}

# Deploy the paperless mail sender gate, then prompt for ALLOWED_SENDERS and DESTINATION
email-gate-deploy:
    cd cloudflare/email-gate && wrangler deploy
    cd cloudflare/email-gate && wrangler secret put ALLOWED_SENDERS
    cd cloudflare/email-gate && wrangler secret put DESTINATION

# Fetch the repository and reconcile the app's Flux Kustomization
reconcile app:
    flux reconcile kustomization {{ quote(app) }} --with-source

# Follow the logs of every labelled pod in the app's namespace
logs app:
    kubectl -n {{ quote(app) }} logs -f -l app.kubernetes.io/name --all-containers --prefix --tail {{ log_tail_lines }} --max-log-requests {{ max_log_streams }}

# Open psql on the app's database on the CNPG primary
psql app:
    #!/usr/bin/env bash
    set -euo pipefail
    app={{ quote(app) }}
    database_file="{{ apps_dir }}/$app/db/database.yaml"
    database="$(yq -e '.spec.name' "$database_file" 2>/dev/null)" || { echo "$database_file is missing or declares no .spec.name, so $app has no database" >&2; exit 1; }
    primary="$(kubectl -n {{ postgres_namespace }} get pod -l {{ primary_selector }} -o jsonpath='{.items[0].metadata.name}')"
    kubectl -n {{ postgres_namespace }} exec -it "$primary" -c postgres -- psql -d "$database"

# Take an on-demand plugin backup of the CNPG cluster to object storage and wait for it
backup:
    #!/usr/bin/env bash
    set -euo pipefail
    backup="$(kubectl create -o name -f - <<EOF
    apiVersion: postgresql.cnpg.io/v1
    kind: Backup
    metadata:
      generateName: {{ postgres_cluster }}-manual-
      namespace: {{ postgres_namespace }}
    spec:
      cluster:
        name: {{ postgres_cluster }}
      method: plugin
      pluginConfiguration:
        name: {{ backup_plugin }}
    EOF
    )"
    echo "Created $backup"
    kubectl -n {{ postgres_namespace }} wait "$backup" --for jsonpath='{.status.phase}'=completed --timeout {{ backup_timeout }}

# Write a pg_dump custom-format dump of the app's database to <app>-<timestamp>.dump in the invocation directory
dump app:
    #!/usr/bin/env bash
    set -euo pipefail
    umask 077
    app={{ quote(app) }}
    database_file="{{ apps_dir }}/$app/db/database.yaml"
    database="$(yq -e '.spec.name' "$database_file" 2>/dev/null)" || { echo "$database_file is missing or declares no .spec.name, so $app has no database" >&2; exit 1; }
    primary="$(kubectl -n {{ postgres_namespace }} get pod -l {{ primary_selector }} -o jsonpath='{.items[0].metadata.name}')"
    out={{ quote(join(invocation_directory(), app)) }}-"$(date +%Y%m%d%H%M%S)".dump
    if ! kubectl -n {{ postgres_namespace }} exec -i "$primary" -c postgres -- pg_dump -Fc -d "$database" > "$out"; then
      rm -f "$out"
      exit 1
    fi
    echo "Wrote $out"

# Replace the app's database with a dump: suspends Flux for the app, scales it to 0, restores, then scales it back
restore app file:
    #!/usr/bin/env bash
    set -euo pipefail
    app={{ quote(app) }}
    database_file="{{ apps_dir }}/$app/db/database.yaml"
    database="$(yq -e '.spec.name' "$database_file" 2>/dev/null)" || { echo "$database_file is missing or declares no .spec.name, so $app has no database" >&2; exit 1; }
    file={{ quote(absolute_path(join(invocation_directory(), file))) }}
    [ -s "$file" ] || { echo "$file is missing or empty" >&2; exit 1; }
    echo "This drops and recreates every object in database $database from $file, with everything in namespace $app scaled to 0 meanwhile."
    read -r -p "Type the app name to continue: " answer
    [ "$answer" = "$app" ] || { echo "Aborted."; exit 1; }
    primary="$(kubectl -n {{ postgres_namespace }} get pod -l {{ primary_selector }} -o jsonpath='{.items[0].metadata.name}')"
    replicas="$(kubectl -n "$app" get deploy,statefulset -o jsonpath='{range .items[*]}{.kind}/{.metadata.name}={.spec.replicas}{"\n"}{end}')"
    resume() {
      set +e
      while IFS='=' read -r workload count; do
        if [ -n "$workload" ]; then kubectl -n "$app" scale "$workload" --replicas "$count"; fi
      done <<< "$replicas"
      flux resume helmrelease --all -n "$app"
      flux resume kustomization "$app"
    }
    trap resume EXIT
    flux suspend kustomization "$app"
    flux suspend helmrelease --all -n "$app"
    kubectl -n "$app" scale deploy,statefulset --all --replicas 0
    deadline=$((SECONDS + {{ scale_down_timeout_seconds }}))
    while [ -n "$(kubectl -n "$app" get pod --field-selector status.phase=Running -o name)" ]; do
      [ "$SECONDS" -lt "$deadline" ] || { echo "Pods in $app are still running" >&2; exit 1; }
      sleep {{ poll_seconds }}
    done
    kubectl -n {{ postgres_namespace }} exec -i "$primary" -c postgres -- \
      pg_restore --clean --if-exists --single-transaction --exit-on-error -d "$database" < "$file"
    echo "Restored $database from $file"

# Copy an app's volumes onto encrypted twins, leaving the app down until the claims are swapped, for example: just encrypt-volumes open-webui --dry-run
encrypt-volumes app *args="":
    bash scripts/encrypt-volumes.sh {{ quote(app) }} {{ args }}

# Store allow-discards in a LUKS volume's header and trim it, for example: just luks-discards llm/open-webui-encrypted
luks-discards volume:
    bash scripts/luks-discards.sh {{ quote(volume) }}

# Run the restore drills, for example: just restore-test --dry-run postgres
restore-test *args="all":
    bash scripts/restore-test.sh {{ args }}

# Copy the newest dumps, etcd snapshot and Longhorn backup set from R2 to a mounted disk, for example: just offline-backup /Volumes/bedrock-keys
offline-backup mountpoint:
    bash scripts/offline-backup.sh {{ quote(join(invocation_directory(), mountpoint)) }}

# Rebuild worker-2, worker-1, control-plane-1 and the router in order, waiting for Ready nodes and healthy Longhorn volumes; add --dry-run to print the steps
deploy-nodes *args="":
    bash scripts/deploy-nodes.sh {{ args }}

# Refresh the default kubeconfig entry from control-plane-1
kubeconfig:
    bash scripts/refresh-kubeconfig.sh

# Bring Flux up on a fresh cluster, confirming each step
bootstrap:
    bash scripts/bootstrap.sh

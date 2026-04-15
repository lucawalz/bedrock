# Sentio Systems — Operations

## Secrets

| Key | Used by | Notes |
|---|---|---|
| `SPRING_DATASOURCE_PASSWORD` | backend | PostgreSQL `sentio` user |
| `KC_DB_PASSWORD` | keycloak | Must match above — same DB user |
| `KEYCLOAK_ADMIN_PASSWORD` | keycloak | Admin console login |
| `KEYCLOAK_ADMIN_CLIENT_SECRET` | backend + keycloak | OAuth client secret |

**Edit secrets:**
```bash
sops kubernetes/clusters/home/secrets/sentio-systems.sops.yaml
```

**After rotating DB password**, sync it to PostgreSQL:
```bash
PG_PASS=$(kubectl get secret postgres-postgresql -n postgres -o jsonpath='{.data.postgres-password}' | base64 -d)
NEW_PASS=$(kubectl get secret sentio-secrets -n sentio-systems -o jsonpath='{.data.SPRING_DATASOURCE_PASSWORD}' | base64 -d)
kubectl exec postgres-postgresql-0 -n postgres -- \
  env PGPASSWORD=$PG_PASS psql -U postgres -c "ALTER USER sentio WITH PASSWORD '$NEW_PASS';"
kubectl rollout restart deployment sentio-backend sentio-keycloak -n sentio-systems
```

---

## Keycloak

**Access admin console** (CSP issues via Traefik — use port-forward):
```bash
kubectl port-forward svc/sentio-keycloak -n sentio-systems 8080:8080
# http://localhost:8080/auth
```

**Fix mismatched client secret:**
```bash
SECRET=$(kubectl get secret sentio-secrets -n sentio-systems -o jsonpath='{.data.KEYCLOAK_ADMIN_CLIENT_SECRET}' | base64 -d)
# Get client ID
kubectl exec deploy/sentio-keycloak -n sentio-systems -c main -- \
  /opt/keycloak/bin/kcadm.sh get clients -r sentio -q clientId=sentio-backend --fields id
# Apply
kubectl exec deploy/sentio-keycloak -n sentio-systems -c main -- \
  /opt/keycloak/bin/kcadm.sh update clients/<ID> -r sentio -s secret=$SECRET
```

**Fix 403 on user registration** (missing realm-management roles):
```bash
kubectl exec deploy/sentio-keycloak -n sentio-systems -c main -- \
  /opt/keycloak/bin/kcadm.sh add-roles -r sentio \
  --uusername service-account-sentio-backend \
  --cclientid realm-management \
  --rolename manage-users --rolename view-users --rolename query-users
```

**Reset Keycloak** (drops and reimports realm from ConfigMap):
```bash
kubectl scale deployment sentio-keycloak -n sentio-systems --replicas=0
PG_PASS=$(kubectl get secret postgres-postgresql -n postgres -o jsonpath='{.data.postgres-password}' | base64 -d)
kubectl exec postgres-postgresql-0 -n postgres -- env PGPASSWORD=$PG_PASS psql -U postgres -c "DROP DATABASE keycloak;"
kubectl exec postgres-postgresql-0 -n postgres -- env PGPASSWORD=$PG_PASS psql -U postgres -c "CREATE DATABASE keycloak OWNER sentio;"
kubectl scale deployment sentio-keycloak -n sentio-systems --replicas=1
```

---

## Image automation

Images are built in the Sentio Systems repo and pushed to GHCR. Flux watches for new tags and commits updates automatically.

| Branch | Tag format | Deployed by Flux |
|---|---|---|
| `main` | `1.0.0` (semver) | Yes |
| `develop` | `1.0.0-dev.<ts>` | No |
| `release/*` | `1.0.0-rc.<ts>` | No |

| Service | Image |
|---|---|
| backend | `ghcr.io/lucawalz/sentio-systems/sentio-backend` |
| frontend | `ghcr.io/lucawalz/sentio-systems/sentio-web` |
| birder | `ghcr.io/lucawalz/sentio-systems/birder-ai` |
| speciesnet | `ghcr.io/lucawalz/sentio-systems/speciesnet-ai` |
| preprocessing | `ghcr.io/lucawalz/sentio-systems/preprocessing-service` |

**Check automation status:**
```bash
flux get image policy -n sentio-systems
flux get image update -n sentio-systems
```

**Pin a version temporarily:**
```bash
flux suspend image update sentio-systems -n sentio-systems
# edit tag in HelmRelease, commit, push
```

---

## Quick reference

```bash
# Pod status
kubectl get pods -n sentio-systems

# Logs
kubectl logs deploy/sentio-backend -n sentio-systems --tail=50

# Restart everything
kubectl rollout restart deployment -n sentio-systems

# Force Flux sync
flux reconcile kustomization cluster-apps --with-source

# Decode all secrets
kubectl get secret sentio-secrets -n sentio-systems \
  -o jsonpath='{.data}' | jq 'to_entries | map({key, value: (.value | @base64d)}) | from_entries'
```

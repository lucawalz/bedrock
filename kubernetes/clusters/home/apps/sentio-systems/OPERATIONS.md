# Sentio Systems - Kubernetes Operations Guide

## Secret Management with SOPS

### Viewing/Editing Secrets

```bash
# Edit encrypted secrets file (decrypts in editor, re-encrypts on save)
sops /Users/luca/nixos-homelab/kubernetes/clusters/home/secrets/sentio-systems.sops.yaml
```

### Rotating Secrets

1. **Edit the secrets file:**
   ```bash
   sops kubernetes/clusters/home/secrets/sentio-systems.sops.yaml
   ```

2. **Update the relevant secret value** (e.g., generate new password):
   ```bash
   openssl rand -base64 32  # Generate new secret
   ```

3. **Commit and push:**
   ```bash
   git add -A && git commit -m "rotate: <secret-name>" && git push
   ```

4. **Reconcile Flux:**
   ```bash
   flux reconcile kustomization cluster-apps --with-source
   ```

5. **Restart affected deployments:**
   ```bash
   kubectl rollout restart deployment sentio-backend sentio-keycloak -n sentio-systems
   ```

### Current Secrets Structure

| Secret Key | Used By | Notes |
|------------|---------|-------|
| `SPRING_DATASOURCE_PASSWORD` | Backend | PostgreSQL password for `sentio` user |
| `KC_DB_PASSWORD` | Keycloak | PostgreSQL password (must match above!) |
| `KEYCLOAK_ADMIN_PASSWORD` | Keycloak | Admin console login |
| `KEYCLOAK_ADMIN_CLIENT_SECRET` | Backend + Keycloak | OAuth client secret |

> **⚠️ IMPORTANT:** `SPRING_DATASOURCE_PASSWORD` and `KC_DB_PASSWORD` must be **identical** - they both use the same PostgreSQL user `sentio`.

### Syncing PostgreSQL Password After Rotation

If you rotate the database password, you must also update PostgreSQL:

```bash
# Get postgres admin password
PG_PASS=$(kubectl get secret postgres-postgresql -n postgres -o jsonpath='{.data.postgres-password}' | base64 -d)

# Get the new password from secrets
NEW_PASS=$(kubectl get secret sentio-secrets -n sentio-systems -o jsonpath='{.data.SPRING_DATASOURCE_PASSWORD}' | base64 -d)

# Update PostgreSQL user
kubectl exec postgres-postgresql-0 -n postgres -- env PGPASSWORD=$PG_PASS psql -U postgres -c "ALTER USER sentio WITH PASSWORD '$NEW_PASS';"

# Restart services
kubectl rollout restart deployment sentio-backend sentio-keycloak -n sentio-systems
```

---

## Keycloak Administration

### Accessing Keycloak Admin Console

**Option 1: Port Forward (Recommended for Admin tasks)**
```bash
kubectl port-forward svc/sentio-keycloak -n sentio-systems 8080:8080
# Access: http://localhost:8080/auth
```

**Option 2: Via CLI (kcadm.sh)**
```bash
# Login
kubectl exec deploy/sentio-keycloak -n sentio-systems -c main -- \
  /opt/keycloak/bin/kcadm.sh config credentials \
  --server http://localhost:8080/auth \
  --realm master \
  --user admin \
  --password $(kubectl get secret sentio-secrets -n sentio-systems -o jsonpath='{.data.KEYCLOAK_ADMIN_PASSWORD}' | base64 -d)

# List clients
kubectl exec deploy/sentio-keycloak -n sentio-systems -c main -- \
  /opt/keycloak/bin/kcadm.sh get clients -r sentio --fields id,clientId

# Update client secret
kubectl exec deploy/sentio-keycloak -n sentio-systems -c main -- \
  /opt/keycloak/bin/kcadm.sh update clients/<CLIENT_ID> -r sentio -s secret=<NEW_SECRET>
```

### Resetting Keycloak (Nuclear Option)

If Keycloak is misconfigured or corrupted:

```bash
# 1. Scale down Keycloak
kubectl scale deployment sentio-keycloak -n sentio-systems --replicas=0

# 2. Wait for pods to terminate
sleep 10

# 3. Drop and recreate database
PG_PASS=$(kubectl get secret postgres-postgresql -n postgres -o jsonpath='{.data.postgres-password}' | base64 -d)
kubectl exec postgres-postgresql-0 -n postgres -- env PGPASSWORD=$PG_PASS psql -U postgres -c "DROP DATABASE keycloak;"
kubectl exec postgres-postgresql-0 -n postgres -- env PGPASSWORD=$PG_PASS psql -U postgres -c "CREATE DATABASE keycloak OWNER sentio;"

# 4. Scale back up (will reimport realm from ConfigMap)
kubectl scale deployment sentio-keycloak -n sentio-systems --replicas=1
```

> **Note:** This will import the realm from `keycloak-realm-template` ConfigMap, which reads from `config-realm.yaml`.

---

## Image Automation & CI/CD

### Tagging Convention

The CI/CD pipeline (GitHub Actions) tags images based on the source branch:

| Branch | Tag Format | Example | Matched by Flux |
|--------|-----------|---------|-----------------|
| `main` | Clean semver | `1.0.0` | ✅ Yes |
| `develop` | `VERSION-dev.TIMESTAMP` | `1.0.0-dev.1769534824` | ❌ No (pre-release) |
| `release/*` | `VERSION-rc.TIMESTAMP` | `1.0.0-rc.1769534824` | ❌ No (pre-release) |

Flux ImagePolicies use `semver: range: '>=0.0.0'` which only matches **stable releases** (no pre-release suffixes). This means only images pushed from `main` trigger automatic deployments.

### How It Works

1. Merge to `main` → CI builds and pushes `ghcr.io/lucawalz/sentio-systems/<image>:<semver>`
2. Flux `ImageRepository` scans GHCR every 1 minute
3. Flux `ImagePolicy` selects the latest stable semver tag
4. Flux `ImageUpdateAutomation` updates the HelmRelease tag and commits to `main`

### Services & Images

| Service | Image | Policy Name |
|---------|-------|-------------|
| Backend | `sentio-backend` | `sentio-backend` |
| Frontend | `sentio-web` | `sentio-frontend` |
| Birder AI | `birder-ai` | `sentio-birder` |
| SpeciesNet AI | `speciesnet-ai` | `sentio-speciesnet` |
| Preprocessing | `preprocessing-service` | `sentio-preprocessing` |

### Manual Image Override

To temporarily pin a specific image version:

```bash
# Edit the HelmRelease directly (Flux will revert on next automation cycle)
kubectl set image deployment/sentio-backend main=ghcr.io/lucawalz/sentio-systems/sentio-backend:1.2.3 -n sentio-systems

# To permanently pin: suspend image automation, then edit the HelmRelease tag
flux suspend image update sentio-systems -n sentio-systems
# Edit the tag in the HelmRelease YAML, commit, and push
```

### Checking Image Automation Status

```bash
# View latest image policies
flux get image policy -n sentio-systems

# View image repositories
flux get image repository -n sentio-systems

# View image update automation
flux get image update -n sentio-systems

# Check which tag was last applied
kubectl get imagepolicy -n sentio-systems -o wide
```

---

## Common Issues & Fixes

### Issue: Keycloak Admin UI Shows CSP/Frame Errors

The external Keycloak admin console has CSP issues when accessed through Traefik. Use port-forward instead:
```bash
kubectl port-forward svc/sentio-keycloak -n sentio-systems 8080:8080
```

### Issue: "Invalid client credentials" on Registration

The `KEYCLOAK_ADMIN_CLIENT_SECRET` in K8s doesn't match what's in Keycloak.

**Fix via CLI:**
```bash
# Get secret from K8s
SECRET=$(kubectl get secret sentio-secrets -n sentio-systems -o jsonpath='{.data.KEYCLOAK_ADMIN_CLIENT_SECRET}' | base64 -d)

# Get client ID
kubectl exec deploy/sentio-keycloak -n sentio-systems -c main -- \
  /opt/keycloak/bin/kcadm.sh get clients -r sentio -q clientId=sentio-backend --fields id

# Update (replace <ID> with actual client ID)
kubectl exec deploy/sentio-keycloak -n sentio-systems -c main -- \
  /opt/keycloak/bin/kcadm.sh update clients/<ID> -r sentio -s secret=$SECRET
```

### Issue: "403 Forbidden" on User Registration

The service account lacks permissions. Grant roles:
```bash
kubectl exec deploy/sentio-keycloak -n sentio-systems -c main -- \
  /opt/keycloak/bin/kcadm.sh add-roles -r sentio \
  --uusername service-account-sentio-backend \
  --cclientid realm-management \
  --rolename manage-users --rolename view-users --rolename query-users
```

### Issue: PostgreSQL "password authentication failed"

Secrets were rotated but PostgreSQL wasn't updated. See "Syncing PostgreSQL Password After Rotation" above.

---

## Useful Commands

```bash
# Check all pod status
kubectl get pods -n sentio-systems

# View logs
kubectl logs deploy/sentio-backend -n sentio-systems --tail=50
kubectl logs deploy/sentio-keycloak -n sentio-systems --tail=50

# Restart all services
kubectl rollout restart deployment -n sentio-systems

# Force Flux reconciliation
flux reconcile kustomization cluster-apps --with-source

# View current secret values (decrypted)
kubectl get secret sentio-secrets -n sentio-systems -o jsonpath='{.data}' | jq 'to_entries | map({key: .key, value: (.value | @base64d)}) | from_entries'
```

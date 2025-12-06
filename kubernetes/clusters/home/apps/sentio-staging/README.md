# Sentio Systems - Staging Environment

This directory contains the Kubernetes manifests for the Staging environment of Sentio Systems.

## Environment Details
- **Namespace**: `sentio-staging`
- **Ingress Domain**: `staging-sentio.syslabs.dev`
- **Container Tag**: `develop`

## Deployment Instructions

1. **Secrets Encryption**:
   - The `secrets.sops.yaml` file contains placeholders.
   - Populate it with real values (database passwords, Keycloak secrets, etc.).
   - Encrypt it using SOPS:
     ```bash
     sops --encrypt --in-place secrets.sops.yaml
     ```
   - Ensure you have the `ghcr-credentials` available or added to the secrets file.

2. **Accessing Services**:
   - Frontend: `https://staging-sentio.syslabs.dev`
   - Backend API: `https://staging-sentio.syslabs.dev/api`
   - Keycloak: `https://staging-sentio.syslabs.dev/auth`
   - Mosquitto (Internal): `sentio-mosquitto.sentio-staging.svc.cluster.local:1883`

3. **Updating Images**:
   - Flux will automatically pull the latest images with the `develop` tag if configured with an ImagePolicy (not currently set up, manual rollout restart may be needed or wait for Flux reconciliation if digest changes).
   - To manually restart all deployments to pull new images:
     ```bash
     kubectl rollout restart deployment -n sentio-staging
     ```

## Troubleshooting
- Check pod status: `kubectl get pods -n sentio-staging`
- Check logs: `kubectl logs -n sentio-staging <pod-name>`
- Describe pod for events: `kubectl describe pod -n sentio-staging <pod-name>`
- Postgres connection issues: Allow time for the database to initialize. Check `sentio-postgresql` logs.

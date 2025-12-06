# Sentio Systems - Production Environment

This directory contains the Kubernetes manifests for the Production environment of Sentio Systems.

## Environment Details
- **Namespace**: `sentio-prod`
- **Ingress Domain**: `sentio.syslabs.dev`
- **Container Tag**: `main`

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
   - Frontend: `https://sentio.syslabs.dev`
   - Backend API: `https://sentio.syslabs.dev/api`
   - Keycloak: `https://sentio.syslabs.dev/auth`
   - Mosquitto (Internal): `sentio-mosquitto.sentio-prod.svc.cluster.local:1883`

3. **Updating Images**:
   - Flux will automatically pull the latest images with the `main` tag.
   - To manually restart all deployments to pull new images:
     ```bash
     kubectl rollout restart deployment -n sentio-prod
     ```

## Troubleshooting
- Check pod status: `kubectl get pods -n sentio-prod`
- Check logs: `kubectl logs -n sentio-prod <pod-name>`
- Describe pod for events: `kubectl describe pod -n sentio-prod <pod-name>`
- Postgres connection issues: Allow time for the database to initialize. Check `sentio-postgresql` logs.

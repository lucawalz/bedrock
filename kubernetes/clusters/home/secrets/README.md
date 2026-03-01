# Kubernetes Secrets (SOPS)

Encrypted Kubernetes secrets managed with SOPS + age. See root `.sops.yaml` for config.

## Adding a Secret

1. Create a Kubernetes Secret manifest:

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: my-secret
     namespace: my-namespace
   type: Opaque
   stringData:
     password: my-password
   ```

2. Encrypt with SOPS:

   ```bash
   sops --encrypt --in-place my-secret.yaml
   mv my-secret.yaml my-secret.sops.yaml
   ```

3. Add to `kustomization.yaml`:

   ```yaml
   resources:
     - my-secret.sops.yaml
   ```

## Editing Secrets

```bash
sops clusters/home/secrets/my-secret.sops.yaml
```

## Current Secrets

- `cloudflare-api-token.sops.yaml` — Cloudflare API token
- `cloudflare-tunnel-secret.sops.yaml` — Cloudflare tunnel token
- `ghcr-auth.sops.yaml` — GitHub Container Registry auth
- `sentio-systems.sops.yaml` — Sentio application secrets

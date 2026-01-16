# Kubernetes Secrets (SOPS)

This directory contains encrypted Kubernetes secrets managed with SOPS.

## Encryption

Secrets are encrypted using **SOPS** with age keys. See root `.sops.yaml` for configuration.

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
   ```

3. Rename to `.sops.yaml`:

   ```bash
   mv my-secret.yaml my-secret.sops.yaml
   ```

4. Add to `kustomization.yaml`:

   ```yaml
   resources:
     - my-secret.sops.yaml
   ```

## Editing Secrets

```bash
# Edit encrypted secret
sops clusters/home/secrets/my-secret.sops.yaml

# Or use Makefile command
make sops-edit FILE=clusters/home/secrets/my-secret.sops.yaml
```

## Common Secrets

- `cloudflare-api-token.sops.yaml` - Cloudflare API token for external-dns
- `postgres-passwords.sops.yaml` - Database passwords
- `grafana-admin.sops.yaml` - Grafana admin credentials

## Age Key Setup

Make sure you have age keys configured:

```bash
# Generate age key (if not exists)
age-keygen -o ~/.config/sops/age/keys.txt

# Get public key
cat ~/.config/sops/age/keys.txt | grep public | cut -d: -f2

# Add to .sops.yaml
```

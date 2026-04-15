# secrets

SOPS-encrypted Kubernetes secrets. Flux decrypts these in-cluster using the age key stored in the `sops-age` secret in `flux-system`.

## Current secrets

| File | Contains |
|---|---|
| `cloudflare-api-token.sops.yaml` | Cloudflare API token for DNS-01 challenges |
| `cloudflare-tunnel-secret.sops.yaml` | Cloudflare Tunnel token |
| `ghcr-auth.sops.yaml` | GitHub Container Registry pull credentials |
| `sentio-systems.sops.yaml` | Sentio app secrets (DB passwords, OAuth secrets) |

## Adding a secret

```bash
# Create and encrypt
cat > my-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: my-secret
  namespace: my-namespace
stringData:
  key: value
EOF
sops --encrypt --in-place my-secret.yaml
mv my-secret.yaml my-secret.sops.yaml
```

Add it to `kustomization.yaml`, commit, push.

## Editing a secret

```bash
sops kubernetes/clusters/home/secrets/my-secret.sops.yaml
```

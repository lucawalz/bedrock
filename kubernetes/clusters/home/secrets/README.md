# Kubernetes secrets

Cluster secrets are committed encrypted with SOPS and the age backend, and Flux decrypts them in-cluster as it reconciles. The encrypted files are safe to keep in a public repository; only the cluster holds the private age key, stored as the `sops-age` secret in `flux-system`.

`/.sops.yaml` at the repo root defines the rule: any file matching `kubernetes/.*/secrets/.*\.sops\.yaml` has its `data` and `stringData` fields encrypted to the cluster's age recipient. The `cluster-secrets` Kustomization decrypts them at apply time.

## What lives here

| File | Holds |
|------|-------|
| `cloudflare-tunnel-secret.sops.yaml` | tunnel token for cloudflared |
| `cloudflare-api-token.sops.yaml` | Cloudflare API token for DNS-01 ACME |
| `rancher-secret.sops.yaml` | Rancher admin password |
| `pgadmin.sops.yaml` | pgAdmin login |
| `litellm-secrets.sops.yaml`, `litellm-db-init.sops.yaml` | LiteLLM keys and database bootstrap |
| `longhorn-backup-credentials.sops.yaml` | object-storage credentials for backups |

## Adding or editing a secret

Edit in place; SOPS re-encrypts on save:

```
sops kubernetes/clusters/home/secrets/<name>.sops.yaml
```

For a new secret, write the plaintext manifest, encrypt it (`sops --encrypt --in-place <name>.yaml` then rename to `<name>.sops.yaml`), and list it in this directory's `kustomization.yaml` so Flux applies it.

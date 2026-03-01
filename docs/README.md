# Documentation

## Setup

**[Setup Process](setup-process.md)** — Full provisioning from bare metal to running cluster

## Reference

| Doc | Covers |
|-----|--------|
| [Kubernetes & Flux](kubernetes-setup.md) | K3s config, Flux bootstrap, adding apps, troubleshooting |
| [Secrets Management](secrets-management.md) | agenix (NixOS) + SOPS (Kubernetes), key rotation |
| [DNS Setup](dns-setup.md) | Cloudflare tunnel, DNS records, certificates, ingress |
| [Disaster Recovery](disaster-recovery.md) | etcd snapshots, Longhorn backups, restoration |

## Quick Reference

```bash
# NixOS
make build HOST=master          # Test build
make switch HOST=master         # Apply configuration

# Kubernetes
make flux-check                 # Flux status
kubectl get nodes               # Cluster status

# Secrets
agenix -e secrets/k3s-token.age                        # NixOS secret
sops kubernetes/.../secret.sops.yaml                   # K8s secret
```

## Troubleshooting

- **Build fails** → Check `secrets/secrets.nix` has correct SSH host keys
- **Secrets won't decrypt** → Verify host SSH keys match actual machine keys
- **Flux not syncing** → `flux get kustomizations` and check for errors
- **K3s down** → `journalctl -u k3s` on the affected node

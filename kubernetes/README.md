# Kubernetes Manifests (Flux GitOps)

This directory contains Kubernetes manifests managed by Flux CD.

## Structure

```
kubernetes/
├── flux-system/          # Flux bootstrap (managed by Flux CLI)
└── clusters/
    └── home/             # Your home cluster
        ├── sources/       # Helm & Git repositories
        ├── config/        # Cluster-wide configuration
        ├── infrastructure/ # Core infrastructure (storage, networking, monitoring)
        ├── apps/          # Applications
        └── secrets/       # Encrypted Kubernetes secrets (SOPS)
```

## Deployment Order

The root `kustomization.yaml` orchestrates deployment in this order:

1. **Sources** - Helm repositories and Git sources
2. **Config** - Cluster-wide configuration
3. **Infrastructure** - Storage → Networking → Monitoring
4. **Apps** - Applications (depends on infrastructure)
5. **Secrets** - Available to all resources

## Bootstrapping Flux

One-time setup (run from your machine with kubectl access):

```bash
just flux-bootstrap
```

Or manually:
```bash
flux bootstrap github \
  --owner=lucawalz \
  --repository=nixos-homelab \
  --path=kubernetes/clusters/home \
  --personal
```

## Flux Commands

```bash
# Check all resources
just flux-check

# Show status
just flux-status

# Manual sync
just flux-sync
```

## Adding Applications

1. Create directory: `clusters/home/apps/category/app-name/`
2. Create Kubernetes manifests or HelmRelease
3. Add to parent `kustomization.yaml`
4. Commit and push - Flux will deploy automatically

## Secrets Management

See `clusters/home/secrets/README.md` for details on managing encrypted secrets with SOPS.


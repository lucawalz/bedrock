# kubernetes

All cluster manifests, reconciled by Flux from the `main` branch.

## Layout

```
kubernetes/clusters/home/
├── flux-system/      # Flux bootstrap (auto-generated, do not edit)
├── config/           # Flux Kustomizations — controls deployment order
├── namespaces/       # All namespace definitions (centralized)
├── sources/          # HelmRepository + OCI source definitions
├── secrets/          # SOPS-encrypted Kubernetes secrets
├── infrastructure/   # Platform services
└── apps/             # Workloads
```

## Deployment order

Flux deploys in layers via `config/`:

```
namespaces + sources   (no deps)
      │
   secrets             (depends: namespaces)
      │
infrastructure         (depends: sources, secrets, namespaces)
      │
   issuers             (depends: infrastructure)
      │
    apps               (depends: infrastructure, issuers)
```

## Adding an app

1. Create `apps/<name>/` with a `HelmRelease` or plain manifests
2. Add a `kustomization.yaml` listing the resources
3. Reference it from `apps/kustomization.yaml`
4. Add a namespace to `namespaces/` if needed
5. Push — Flux reconciles within 1 minute

## Flux bootstrap (one-time)

```bash
export GITHUB_TOKEN=<pat>
flux bootstrap github \
  --owner=lucawalz \
  --repository=nixos-homelab \
  --path=kubernetes/clusters/home \
  --personal
```

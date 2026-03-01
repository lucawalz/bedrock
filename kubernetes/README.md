# Kubernetes Manifests (Flux GitOps)

All Kubernetes manifests, managed by Flux CD.

## Structure

```
kubernetes/
└── clusters/
    └── home/             # Home cluster
        ├── namespaces/    # Centralized namespace definitions
        ├── sources/       # Helm & OCI repositories
        ├── config/        # Flux Kustomizations (deployment order)
        ├── secrets/       # Encrypted Kubernetes secrets (SOPS)
        ├── infrastructure/ # Core infrastructure (storage, networking, databases, monitoring, cicd)
        ├── apps/          # Applications
        └── flux-system/   # Flux bootstrap (auto-managed)
```

## Deployment Order

The `config/` Flux Kustomizations orchestrate deployment:

1. **Namespaces** — All namespace definitions (no dependencies)
2. **Sources** — Helm/OCI repositories (no dependencies)
3. **Secrets** — Encrypted secrets (depends: namespaces)
4. **Infrastructure** — Storage, Networking, Databases, Monitoring, CI/CD (depends: sources, secrets, namespaces)
5. **Issuers** — cert-manager ClusterIssuers (depends: infrastructure, namespaces)
6. **Apps** — Applications (depends: infrastructure, issuers, namespaces)

## Flux Bootstrap

Prerequisites: kubectl access via kubeconfig, GitHub PAT with `repo` scope.

```bash
export GITHUB_TOKEN=<token>
flux bootstrap github \
  --owner=lucawalz \
  --repository=nixos-homelab \
  --path=kubernetes/clusters/home \
  --personal
```

Or via Makefile: `make flux-bootstrap`

## Flux Commands

```bash
make flux-check      # Check all resources
make flux-status     # Show status
make flux-sync       # Manual sync
```

## Adding Applications

1. Create directory: `clusters/home/apps/app-name/`
2. Add Kubernetes manifests or HelmRelease
3. Add to parent `kustomization.yaml`
4. Add namespace to `clusters/home/namespaces/`
5. Commit and push — Flux deploys automatically

## Secrets (SOPS)

SOPS-encrypted secrets use age keys. See `clusters/home/secrets/README.md` and [docs/secrets-management.md](../docs/secrets-management.md).

```bash
# Create sops-age secret in cluster (one-time)
cat ~/.config/sops/age/keys.txt | \
  kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey=/dev/stdin
```

# Kubernetes Manifests (Flux GitOps)

This directory contains Kubernetes manifests managed by Flux CD.

## Structure

```
kubernetes/
├── flux-system/          # Flux bootstrap (created by flux bootstrap command)
└── clusters/
    └── home/             # Your home cluster
        ├── sources/       # Helm & Git repositories
        ├── config/        # Cluster-wide configuration
        ├── infrastructure/ # Core infrastructure (storage, networking, monitoring)
        ├── apps/          # Applications
        └── secrets/       # Encrypted Kubernetes secrets (SOPS)
```

**Note**: The `flux-system/` directory will be automatically created when you run the bootstrap command below.

## Deployment Order

The root `kustomization.yaml` orchestrates deployment in this order:

1. **Sources** - Helm repositories and Git sources
2. **Config** - Cluster-wide configuration
3. **Infrastructure** - Storage → Networking → Monitoring
4. **Apps** - Applications (depends on infrastructure)
5. **Secrets** - Available to all resources

## Prerequisites

Before bootstrapping Flux, ensure:

1. **kubectl access from your local machine**:
   ```bash
   # Copy kubeconfig from master node
   scp master:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s-config
   
   # Edit ~/.kube/k3s-config and change:
   # server: https://127.0.0.1:6443
   # to:
   # server: https://MASTER_IP:6443
   
   # Use the config
   export KUBECONFIG=~/.kube/k3s-config
   
   # Test it works
   kubectl get nodes
   ```

2. **GitHub personal access token** with repo permissions:
   - Go to GitHub Settings → Developer settings → Personal access tokens
   - Create token with `repo` scope
   - Export it: `export GITHUB_TOKEN=your_token_here`

3. **Flux CLI installed** (already in your dev shell):
   ```bash
   flux --version
   ```

## Bootstrapping Flux

**Run this from your local machine** (not on the master node):

```bash
# Export your GitHub token
export GITHUB_TOKEN=your_token_here

# Bootstrap Flux
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

This will:
- Create `kubernetes/flux-system/` directory with Flux controllers
- Commit and push to your repository
- Deploy Flux to your cluster
- Set up GitOps sync from this repository

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

Before deploying applications with secrets:

1. **Generate an age key** (if you haven't already):
   ```bash
   age-keygen -o ~/.config/sops/age/keys.txt
   ```

2. **Update `.sops.yaml`** with your age public key:
   ```yaml
   creation_rules:
     - path_regex: kubernetes/.*/secrets/.*\.sops\.yaml$
       encrypted_regex: ^(data|stringData)$
       age: age1your_public_key_here
   ```

3. **Create a Kubernetes secret** with your age key:
   ```bash
   cat ~/.config/sops/age/keys.txt | \
     kubectl create secret generic sops-age \
     --namespace=flux-system \
     --from-file=age.agekey=/dev/stdin
   ```

See `clusters/home/secrets/README.md` for details on managing encrypted secrets with SOPS.

## Verification

After bootstrapping, verify Flux is running:

```bash
# Check Flux components
kubectl get pods -n flux-system

# Check all Flux resources
just flux-check

# Watch Flux reconciliation
flux get kustomizations --watch
```


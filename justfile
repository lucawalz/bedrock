# Build and switch NixOS config for a host
switch HOST:
    sudo nixos-rebuild switch --flake .#{{HOST}}

# Test build without switching
build HOST:
    nixos-rebuild build --flake .#{{HOST}}

# Bootstrap Flux on the cluster (one-time setup)
flux-bootstrap:
    flux bootstrap github \
      --owner=lucawalz \
      --repository=nixos-homelab \
      --path=kubernetes/clusters/home \
      --personal

# Encrypt a secret for Kubernetes
sops-encrypt FILE:
    sops --encrypt --in-place {{FILE}}

# Edit an encrypted Kubernetes secret
sops-edit FILE:
    sops {{FILE}}

# Check all Flux resources
flux-check:
    flux get all -A

# Show Flux status
flux-status:
    flux get all -A --status

# Sync Flux manually
flux-sync:
    flux reconcile kustomization -A

# Show K3s cluster info
k3s-info:
    kubectl cluster-info
    kubectl get nodes

# Update flake lock
update:
    nix flake update


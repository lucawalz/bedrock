# NixOS + K3s Homelab

A complete homelab setup using NixOS for operating system management and K3s for Kubernetes orchestration, with Flux CD for GitOps.

## 📋 Overview

This repository contains a production-ready homelab configuration with:

- **NixOS** - Declarative operating system configuration
- **K3s** - Lightweight Kubernetes distribution
- **Flux CD** - GitOps continuous deployment
- **Longhorn** - Distributed block storage
- **Traefik** - Ingress controller
- **cert-manager** - TLS certificate management
- **Prometheus/Grafana** - Monitoring and observability

## 🏗️ Architecture

- **master** - K3s control plane (master) node
- **worker-1** - K3s worker (agent) node
- **worker-2** - Future worker node (placeholder)

## 🚀 Quick Start

### Prerequisites

- NixOS installed on target machines
- SSH access to all nodes
- Age keys generated for secrets management
- GitHub repository (for Flux GitOps)

### Initial Setup

1. **Clone repository**:
   ```bash
   git clone https://github.com/lucawalz/nixos-homelab.git
   cd nixos-homelab
   ```

2. **Development shell** (auto-loads with direnv):
   ```bash
   # If direnv is installed
   direnv allow
   
   # Or manually
   nix develop
   ```

3. **Configure secrets**:
   - Get host SSH public keys: `ssh-keyscan -t ed25519 master`
   - Update `secrets/secrets.nix` with host keys
   - Create K3s token: `agenix -e secrets/k3s-token.age`

4. **Deploy to nodes**:
   ```bash
   just switch master
   just switch worker-1
   ```

5. **Bootstrap Flux** (one-time):
   ```bash
   just flux-bootstrap
   ```

6. **Configure DNS** for `syslabs.dev`:
   - Point DNS records to your public IP (see [DNS Setup Guide](docs/dns-setup.md))
   - Update email in cert-manager cluster issuers

7. **Verify deployment**:
   ```bash
   just flux-check
   kubectl get nodes
   ```

## 📁 Repository Structure

```
nixos-homelab/
├── hosts/              # Per-host NixOS configurations
├── roles/              # Role-based configs (k3s-server, k3s-agent)
├── secrets/            # Encrypted NixOS secrets (agenix)
├── kubernetes/         # Kubernetes manifests (Flux GitOps)
├── docs/               # Extended documentation
└── modules/            # Custom NixOS modules (optional)
```

See individual README files in each directory for details.

## 📖 Documentation

- **[NixOS Setup Guide](docs/nixos-setup.md)** - Installation and configuration
- **[Kubernetes Setup Guide](docs/kubernetes-setup.md)** - K3s and Flux setup
- **[DNS Setup Guide](docs/dns-setup.md)** - Configuring syslabs.dev domain
- **[Secrets Management](docs/secrets-management.md)** - Managing encrypted secrets
- **[Disaster Recovery](docs/disaster-recovery.md)** - Backup and recovery procedures

## 🛠️ Common Tasks

### Update NixOS Configuration

```bash
# Test build
just build master

# Apply changes
just switch master
```

### Check Flux Status

```bash
just flux-check
just flux-status
```

### Add a New Application

1. Create directory: `kubernetes/clusters/home/apps/category/app-name/`
2. Create manifests (Deployment, Service, Ingress, etc.)
3. Add to parent `kustomization.yaml`
4. Commit and push - Flux deploys automatically

### Edit Secrets

```bash
# NixOS secrets (agenix)
agenix -e secrets/k3s-token.age

# Kubernetes secrets (SOPS)
just sops-edit kubernetes/clusters/home/secrets/my-secret.sops.yaml
```

## 🔐 Secrets Management

- **NixOS secrets**: Encrypted with agenix (age) using SSH host keys
- **Kubernetes secrets**: Encrypted with SOPS (age keys)

See [Secrets Management Guide](docs/secrets-management.md) for details.

## 🔧 Configuration

### Host Configuration

Edit `hosts/home-XX/default.nix` for host-specific settings:
- Hostname
- Network configuration (static IP, etc.)
- Role assignments

### Cluster Configuration

Edit `kubernetes/clusters/home/config/cluster-settings.yaml` for:
- Cluster domain
- Timezone
- Other cluster-wide settings

### Infrastructure

Infrastructure components are in `kubernetes/clusters/home/infrastructure/`:
- Storage (Longhorn)
- Networking (Traefik, cert-manager)
- Monitoring (Prometheus/Grafana)

## 🌐 Accessing Services

- **Traefik Dashboard**: `traefik.syslabs.dev`
- **Grafana**: `grafana.syslabs.dev`
- **Longhorn UI**: Port-forward or Ingress

## 📝 Adding a New Host

1. Generate hardware config on target: `nixos-generate-config --root /mnt`
2. Create `hosts/worker-X/default.nix`
3. Add to `flake.nix` nixosConfigurations
4. Update `secrets/secrets.nix` with host's SSH key
5. Deploy: `just switch worker-X`

## 🔄 GitOps Workflow

1. Edit Kubernetes manifests locally
2. Commit and push changes
3. Flux automatically detects and applies changes
4. Monitor with `just flux-check`

## 🐛 Troubleshooting

### NixOS Build Fails

- Check all imports exist and paths are correct
- Verify secrets are properly encrypted
- Review build errors: `nixos-rebuild build --flake .#master`

### Flux Not Syncing

- Check Flux status: `flux get sources git`
- Verify repository access
- Manual sync: `flux reconcile kustomization -A`

### Pods Not Starting

- Check logs: `kubectl logs -n <namespace> <pod>`
- Check events: `kubectl describe pod -n <namespace> <pod>`
- Verify PVCs if using storage

### Secrets Issues

- Verify host SSH keys in `secrets/secrets.nix`
- Check age keys for SOPS secrets
- See [Secrets Management Guide](docs/secrets-management.md)

## 📚 Resources

- [NixOS Manual](https://nixos.org/manual/nixos/)
- [K3s Documentation](https://docs.k3s.io/)
- [Flux Documentation](https://fluxcd.io/docs/)
- [Agenix](https://github.com/ryantm/agenix)
- [SOPS](https://github.com/getsops/sops)

## 🤝 Contributing

This is a personal homelab repository. Feel free to fork and adapt for your needs!

## 📄 License

MIT

---

**Note**: This configuration is designed for a homelab environment. Adjust security settings, resource limits, and networking for your specific needs.


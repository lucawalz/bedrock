# Documentation Index

Welcome to the NixOS Homelab documentation! This index will help you find the right guide for your needs.

## Getting Started

### New Users (Start Here!)
**[Complete Setup Guide](complete-setup-guide.md)** - Step-by-step guide from zero to running homelab
- Prerequisites and planning
- Environment preparation  
- NixOS installation with nixos-anywhere
- Secrets configuration
- Kubernetes and Flux setup
- DNS and networking
- Verification and next steps

### Existing NixOS Users
**[Quick Start (Migration)](../QUICK_START.md)** - For users migrating from existing NixOS setups
- Fresh installation with nixos-anywhere
- Migration from existing systems
- Troubleshooting deployment issues

## Detailed Guides

### System Configuration
**[NixOS Configuration Reference](nixos-setup.md)** - Advanced NixOS configuration
- Manual installation methods
- Host configuration details
- Hardware configuration
- Adding new hosts
- NixOS troubleshooting

### Kubernetes & GitOps
**[Kubernetes & Flux Reference](kubernetes-setup.md)** - K3s and Flux configuration
- K3s cluster management
- Flux GitOps workflow
- Adding applications
- HelmRelease configuration
- Monitoring and troubleshooting

### Security & Secrets
**[Secrets Management Reference](secrets-management.md)** - Advanced secrets management
- agenix for NixOS secrets
- SOPS for Kubernetes secrets
- Key rotation and management
- Troubleshooting decryption issues

### Networking & Access
**[DNS Setup Guide](dns-setup.md)** - Configuring external access
- Domain configuration
- DNS records setup
- Certificate management
- Ingress configuration

### Operations & Maintenance
**[Disaster Recovery](disaster-recovery.md)** - Backup and recovery procedures
- System backups
- Data recovery
- Cluster restoration
- Emergency procedures

## Quick Reference

### Common Commands
```bash
# NixOS operations
just build master          # Test configuration
just switch master         # Apply configuration
just switch worker-1       # Deploy to worker

# Kubernetes operations  
just flux-check           # Check Flux status
just flux-bootstrap       # Bootstrap Flux GitOps
kubectl get nodes         # Check cluster status

# Secrets management
agenix -e secrets/k3s-token.age              # Edit NixOS secret
just sops-edit kubernetes/.../secret.yaml    # Edit K8s secret
```

### Repository Structure
```
nixos-homelab/
├── hosts/              # Per-host NixOS configurations
├── roles/              # Role-based configs (k3s-server, k3s-agent)  
├── secrets/            # Encrypted NixOS secrets (agenix)
├── kubernetes/         # Kubernetes manifests (Flux GitOps)
├── docs/               # Documentation
└── modules/            # Custom NixOS modules
```

### Key Files
- `flake.nix` - Main NixOS configuration entry point
- `secrets/secrets.nix` - SSH keys for secret decryption
- `hosts/common.nix` - Shared configuration across all hosts
- `kubernetes/clusters/home/kustomization.yaml` - Main Flux entry point

## Troubleshooting

### Quick Fixes
- **Build fails**: Check `secrets/secrets.nix` has correct SSH host keys
- **Secrets won't decrypt**: Verify host SSH keys match actual machine keys  
- **Flux not syncing**: Check GitHub repository access and webhook configuration
- **Pods not starting**: Verify resource limits and storage availability

### Getting Help
1. Check the specific guide for your component (NixOS, Kubernetes, etc.)
2. Review the troubleshooting sections in each guide
3. Check logs: `journalctl -u k3s` (NixOS) or `kubectl logs` (Kubernetes)
4. Verify configuration syntax and file paths

## Contributing

This is a personal homelab repository, but feel free to:
- Fork and adapt for your own needs
- Submit issues for documentation improvements
- Share your own configurations and learnings

---

**Need immediate help?** Start with the [Complete Setup Guide](complete-setup-guide.md) for a full walkthrough.
# Migration Guide

This document explains what changed during the repository restructure and what you need to do.

## What Changed

### Repository Structure

- **Old structure**: All config in `nixos/` directory
- **New structure**: Organized into `hosts/`, `roles/`, `secrets/`, `kubernetes/`, etc.

### Host Names

- **Old**: `master` and `worker-1`
- **New**: `master` and `worker-1` (kept same names)

### Flake Location

- **Old**: `nixos/flake.nix`
- **New**: `flake.nix` (root)

## Migration Steps

### 1. Update Host Names (if needed)

Your machines are already named `master` and `worker-1`, which matches the new structure. No renaming needed!

### 2. Move Secrets

If you have an existing `k3s-token.age` file:

```bash
# If secrets were in nixos/secrets/
mv nixos/secrets/k3s-token.age secrets/k3s-token.age

# Update secrets.nix with your actual host SSH keys
```

### 3. Update Secrets Configuration

Edit `secrets/secrets.nix` and replace the placeholder SSH keys:

```bash
# Get host SSH public keys
ssh-keyscan -t ed25519 master
ssh-keyscan -t ed25519 worker-1

# Update secrets/secrets.nix with actual keys
```

### 4. Update Hardware Configurations

The `hardware-configuration.nix` files are placeholders. You need to:

**Option A: Use existing hardware configs**
```bash
# If you have existing hardware configs, copy them:
cp nixos/hardware-configuration.nix hosts/master/hardware-configuration.nix
```

**Option B: Regenerate on each host**
```bash
# On each host machine
nixos-generate-config --root /mnt --dir /path/to/repo/hosts/master
```

### 5. Update Disko Configs

Disko configs have been copied to each host directory. Review and update them if needed:

- `hosts/master/disko-config.nix`
- `hosts/worker-1/disko-config.nix`

### 6. Update Networking Configuration

In `roles/k3s-agent.nix`, the server address is already set correctly:

```nix
serverAddr = "https://master:6443";  # Already correct
```

Or use IP address:
```nix
serverAddr = "https://192.168.1.10:6443";
```

### 7. Test Configuration

Before deploying, test the configuration:

```bash
# Test build
just build master
# or
nixos-rebuild build --flake .#master

# If successful, deploy
just switch master
```

### 8. Clean Up Old Files (after migration)

Once everything is working, you can remove the old `nixos/` directory:

```bash
# Backup first!
cp -r nixos nixos.backup

# Remove after confirming new structure works
rm -rf nixos
```

### 9. Update Git Remote (if needed)

If your repository URL changed, update it:

```bash
git remote set-url origin https://github.com/lucawalz/nixos-homelab.git
```

## Troubleshooting

### "Cannot find module" errors

- Check that all import paths are correct relative to the file location
- Verify `hardware-configuration.nix` exists in each host directory

### "Cannot decrypt secret" errors

- Verify SSH keys in `secrets/secrets.nix` match actual host keys
- Re-encrypt secrets if needed: `agenix -e secrets/k3s-token.age`

### K3s agent can't connect

- Check `serverAddr` in `roles/k3s-agent.nix`
- Verify firewall allows port 6443
- Check that master node has K3s running: `sudo systemctl status k3s`

## Next Steps

After migration is complete:

1. **Set up Flux CD** (if not already done):
   ```bash
   just flux-bootstrap
   ```

2. **Review Kubernetes manifests**:
   - Customize `kubernetes/clusters/home/` as needed
   - Update domain names, emails, etc.

3. **Read the documentation**:
   - [NixOS Setup Guide](docs/nixos-setup.md)
   - [Kubernetes Setup Guide](docs/kubernetes-setup.md)
   - [Secrets Management](docs/secrets-management.md)

## Getting Help

If you encounter issues:

1. Check the relevant documentation in `docs/`
2. Review error messages carefully
3. Test builds with `just build <host>` before deploying
4. Check that all paths and references are correct


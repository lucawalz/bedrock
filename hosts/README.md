# Host Configurations

This directory contains per-host NixOS configurations.

## Structure

Each host directory (`master`, `worker-1`, etc.) contains:
- `default.nix` - Host-specific configuration (hostname, IP address, role imports)
- `hardware-configuration.nix` - Auto-generated hardware configuration (created by `nixos-generate-config`)

## Shared Configuration

- `common.nix` - Shared configuration applied to all hosts:
  - User accounts and SSH keys
  - Timezone and locale
  - Base packages
  - SSH server config
  - Nix settings (flakes, GC)

## Hosts

- **master** - K3s control plane (master) node
- **worker-1** - K3s worker (agent) node
- **worker-2** - Future worker node (placeholder)

## Adding a New Host

1. Generate hardware config on the target machine:
   ```bash
   nixos-generate-config --root /mnt --dir ./hosts/worker-X
   ```

2. Create `hosts/worker-X/default.nix`:
   ```nix
   { config, pkgs, meta, ... }:
   {
     imports = [
       ./hardware-configuration.nix
       ../common.nix
       # Add roles as needed
     ];
     
     networking.hostName = "worker-X";
     # Configure networking, etc.
   }
   ```

3. Add the host to `flake.nix` in the `nixosConfigurations` set.


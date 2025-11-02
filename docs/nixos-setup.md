# NixOS Installation & Configuration Guide

## Prerequisites

- Hardware with NixOS-compatible hardware
- SSH access to the machines
- Age keys generated for secrets management

## Installation Methods

### Method 1: nixos-anywhere (Recommended)

The fastest and most reliable method:

```bash
# From your local machine
nixos-anywhere --flake .#master root@TARGET_IP
```

This automatically:
- Partitions the disk (using disko configuration)
- Installs NixOS
- Deploys secrets
- Configures K3s

See `QUICK_START.md` for detailed steps.

### Method 2: Manual Installation

If you prefer manual installation or nixos-anywhere isn't available:

#### 1. Boot from NixOS ISO

Download the latest NixOS ISO and boot the target machine.

#### 2. Partition Disk (Optional - disko can do this)

If not using disko, manually partition:

```bash
sudo -i
# Partition and format disk (adjust device as needed)
# Example for UEFI:
parted /dev/nvme0n1 -- mklabel gpt
parted /dev/nvme0n1 -- mkpart ESP fat32 1MiB 512MiB
parted /dev/nvme0n1 -- set 1 esp on
parted /dev/nvme0n1 -- mkpart primary 512MiB 100%

mkfs.fat -F 32 -n boot /dev/nvme0n1p1
mkfs.ext4 -L nixos /dev/nvme0n1p2

mount /dev/nvme0n1p2 /mnt
mkdir -p /mnt/boot
mount /dev/nvme0n1p1 /mnt/boot
```

#### 3. Clone Repository

```bash
git clone https://github.com/YOUR_USERNAME/nixos-homelab.git /mnt/etc/nixos/homelab
cd /mnt/etc/nixos/homelab
```

#### 4. Install NixOS

```bash
cd /mnt/etc/nixos/homelab
nixos-install --flake .#master
```

Follow the prompts to set root password.

#### 5. Reboot

```bash
reboot
```

**Note**: Secrets and K3s token are already configured in the repository and will be automatically deployed.

## Updating Configuration

After initial installation, update the configuration:

```bash
cd /etc/nixos/homelab
git pull
sudo nixos-rebuild switch --flake .#master
```

Or from your local machine:

```bash
just switch master
```

## Adding a New Host

1. Follow the installation steps above
2. Add the host to `flake.nix`:
   ```nix
   worker-2 = nixpkgs.lib.nixosSystem {
     system = "x86_64-linux";
     specialArgs = { meta = { hostname = "worker-2"; }; };
     modules = [ ./hosts/worker-2 ];
   };
   ```
3. Update `secrets/secrets.nix` with the new host's public key
4. Create host configuration in `hosts/worker-2/`

## Troubleshooting

### Can't decrypt secrets

Make sure the host's SSH key is in `secrets/secrets.nix` and matches the actual host key.

### Build fails

Check that all imports are correct and paths are relative to the repository root.

### Network issues

Ensure `hardware-configuration.nix` is properly generated and network interfaces are configured.


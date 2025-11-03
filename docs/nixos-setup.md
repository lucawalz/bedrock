# NixOS Configuration Reference

This document covers NixOS-specific configuration details and advanced scenarios.

**For complete setup instructions, see the [Complete Setup Guide](complete-setup-guide.md).**

## Overview

This homelab uses NixOS for declarative, reproducible system configuration with:
- **Flake-based configuration** for reproducible builds
- **Disko** for automatic disk partitioning
- **Agenix** for encrypted secrets management
- **Role-based configuration** for different node types

## Installation Methods

### Method 1: nixos-anywhere

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

See the [Complete Setup Guide](complete-setup-guide.md) for detailed steps.

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

## Configuration Structure

### Flake Configuration

The main entry point is `flake.nix`, which defines:

```nix
nixosConfigurations = {
  master = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = { meta = { hostname = "master"; }; };
    modules = [ ./hosts/master ];
  };
  worker-1 = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    specialArgs = { meta = { hostname = "worker-1"; }; };
    modules = [ ./hosts/worker-1 ];
  };
};
```

### Host Configuration

Each host has its own directory in `hosts/` with:
- `default.nix` - Main host configuration
- `hardware-configuration.nix` - Hardware-specific settings
- `disko-config.nix` - Disk partitioning configuration

### Role-Based Configuration

Roles are defined in `roles/` and imported by hosts:
- `k3s-server.nix` - Kubernetes master node configuration
- `k3s-agent.nix` - Kubernetes worker node configuration
- `common-services.nix` - Shared services across all nodes
- `monitoring.nix` - Monitoring stack configuration

## Secrets Management

### Agenix Integration

NixOS secrets are managed with agenix:

```nix
# In secrets/secrets.nix
let
  master = "ssh-ed25519 AAAAC3... root@master";
  worker-1 = "ssh-ed25519 AAAAC3... root@worker-1";
  yourname = "ssh-ed25519 YOUR_KEY your-email@example.com";
in
{
  "k3s-token.age".publicKeys = [ master worker-1 yourname ];
}
```

### Creating Secrets

```bash
# Create a new secret
agenix -e secrets/new-secret.age

# Edit existing secret
agenix -e secrets/k3s-token.age
```

### Using Secrets in Configuration

```nix
# In a NixOS module
age.secrets.k3s-token = {
  file = ../secrets/k3s-token.age;
  owner = "root";
  group = "root";
  mode = "0400";
};

# Reference in configuration
services.k3s.tokenFile = config.age.secrets.k3s-token.path;
```

## Disk Configuration with Disko

### Standard Configuration

The disko configuration handles automatic partitioning:

```nix
# hosts/master/disko-config.nix
{
  disko.devices = {
    disk = {
      main = {
        device = "/dev/nvme0n1";  # Adjust for your hardware
        type = "disk";
        content = {
          type = "gpt";
          partitions = {
            ESP = {
              size = "512M";
              type = "EF00";
              content = {
                type = "filesystem";
                format = "vfat";
                mountpoint = "/boot";
              };
            };
            luks = {
              size = "100%";
              content = {
                type = "luks";
                name = "crypted";
                content = {
                  type = "filesystem";
                  format = "ext4";
                  mountpoint = "/";
                };
              };
            };
          };
        };
      };
    };
  };
}
```

### Customizing for Different Hardware

Update the `device` field for different disk types:
- NVMe: `/dev/nvme0n1`
- SATA: `/dev/sda`
- VirtIO: `/dev/vda`

## Adding a New Host

### Step 1: Create Host Directory

```bash
mkdir -p hosts/worker-2
```

### Step 2: Create Host Configuration

```nix
# hosts/worker-2/default.nix
{ config, lib, pkgs, meta, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./disko-config.nix
    ../common.nix
    ../../roles/k3s-agent.nix
    ../../roles/common-services.nix
  ];

  networking.hostName = meta.hostname;
  
  # Host-specific configuration
  networking.interfaces.eth0.ipv4.addresses = [{
    address = "192.168.1.12";
    prefixLength = 24;
  }];
}
```

### Step 3: Generate Hardware Configuration

```bash
# On the target machine
nixos-generate-config --show-hardware-config > /tmp/hardware-config.nix
# Copy content to hosts/worker-2/hardware-configuration.nix
```

### Step 4: Copy Disko Configuration

```bash
cp hosts/worker-1/disko-config.nix hosts/worker-2/disko-config.nix
# Adjust device path if needed
```

### Step 5: Update Flake Configuration

```nix
# Add to flake.nix nixosConfigurations
worker-2 = nixpkgs.lib.nixosSystem {
  system = "x86_64-linux";
  specialArgs = { meta = { hostname = "worker-2"; }; };
  modules = [ ./hosts/worker-2 ];
};
```

### Step 6: Update Secrets

```bash
# Get the new host's SSH key
ssh-keyscan -t ed25519 worker-2

# Add to secrets/secrets.nix
let
  # ... existing keys ...
  worker-2 = "ssh-ed25519 AAAAC3... root@worker-2";
in
{
  "k3s-token.age".publicKeys = [ master worker-1 worker-2 yourname ];
}
```

### Step 7: Deploy

```bash
# Test build first
nix build .#nixosConfigurations.worker-2.config.system.build.toplevel

# Deploy with nixos-anywhere
nixos-anywhere --flake .#worker-2 root@TARGET_IP
```

## Advanced Configuration

### Custom Modules

Create reusable modules in `modules/`:

```nix
# modules/custom-service/default.nix
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.custom-service;
in
{
  options.services.custom-service = {
    enable = mkEnableOption "custom service";
    port = mkOption {
      type = types.int;
      default = 8080;
      description = "Port to listen on";
    };
  };

  config = mkIf cfg.enable {
    # Service configuration
  };
}
```

### Network Configuration

#### Static IP Configuration

```nix
networking = {
  interfaces.eth0.ipv4.addresses = [{
    address = "192.168.1.10";
    prefixLength = 24;
  }];
  defaultGateway = "192.168.1.1";
  nameservers = [ "1.1.1.1" "8.8.8.8" ];
};
```

#### DHCP Configuration

```nix
networking.interfaces.eth0.useDHCP = true;
```

### Firewall Configuration

```nix
networking.firewall = {
  enable = true;
  allowedTCPPorts = [ 22 80 443 6443 ];
  allowedUDPPorts = [ 51820 ]; # WireGuard
};
```

## Troubleshooting

### Build Failures

**Syntax errors**: Check Nix syntax with `nix-instantiate --parse`
**Import errors**: Verify all file paths are correct and relative to repository root
**Missing dependencies**: Ensure all required packages are in `environment.systemPackages`

### Secret Decryption Issues

**Wrong SSH keys**: Verify keys in `secrets/secrets.nix` match actual host keys
**Permission issues**: Check that agenix service is enabled and running
**Key format**: Ensure SSH keys are ed25519 format

### Hardware Issues

**Disk not found**: Update device paths in disko configuration
**Network interfaces**: Check interface names with `ip link show`
**Boot issues**: Verify UEFI/BIOS settings match disko configuration

### K3s Issues

**Service not starting**: Check `systemctl status k3s` or `systemctl status k3s-agent`
**Token issues**: Verify K3s token is properly decrypted in `/run/agenix/k3s-token`
**Network connectivity**: Ensure firewall allows K3s ports (6443, 10250, etc.)

### Performance Tuning

**Memory usage**: Adjust `nix.settings.max-jobs` and `nix.settings.cores`
**Storage**: Configure appropriate filesystem options in disko
**Network**: Tune kernel network parameters for high-throughput workloads

## Maintenance

### Regular Updates

```bash
# Update flake inputs
nix flake update

# Test build
just build master

# Apply updates
just switch master
```

### Garbage Collection

```bash
# On each host
nix-collect-garbage -d
```

### Monitoring System Health

```bash
# Check system status
systemctl status
journalctl -f

# Check disk usage
df -h
nix-store --gc --print-roots | wc -l
```


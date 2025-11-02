# NixOS Installation & Configuration Guide

## Prerequisites

- Hardware with NixOS-compatible hardware
- SSH access to the machines
- Age keys generated for secrets management

## Initial Installation

### 1. Boot from NixOS ISO

Download the latest NixOS ISO and boot the target machine.

### 2. Generate Hardware Configuration

Once booted into the NixOS installer:

```bash
# Partition and format disk (adjust device as needed)
sudo -i

# Mount the root partition
mount /dev/nvme0n1p2 /mnt
mount /dev/nvme0n1p1 /mnt/boot

# Generate hardware configuration
nixos-generate-config --root /mnt
```

### 3. Clone This Repository

```bash
cd /mnt
git clone https://github.com/lucawalz/nixos-homelab.git /mnt/etc/nixos/homelab
cd /mnt/etc/nixos/homelab
```

### 4. Configure Secrets

Before first deployment, you need to set up secrets:

#### Get Host SSH Keys

   ```bash
   # From the target machine, get the SSH host key
   cat /etc/ssh/ssh_host_ed25519_key.pub
   ```

#### Update secrets.nix

Edit `secrets/secrets.nix` and add the host's public key:

```nix
let
  master = "ssh-ed25519 AAAAC3...";  # The key from above
in
{
  "k3s-token.age".publicKeys = [ master luca ];
}
```

#### Create K3s Token

```bash
# Generate a random token
openssl rand -hex 32 > /tmp/k3s-token

# Encrypt it with agenix
agenix -e secrets/k3s-token.age
# Paste the token content, save and exit
```

### 5. Update Host Configuration

Edit `hosts/home-XX/default.nix` and:
- Adjust hostname if needed
- Configure networking (static IP, etc.)
- Add/remove role imports

### 6. Install NixOS

```bash
cd /mnt/etc/nixos/homelab
nixos-install --flake .#master
```

Follow the prompts to set root password.

### 7. Reboot

```bash
reboot
```

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


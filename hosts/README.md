# Host Configurations

This directory contains per-host NixOS configurations.

## Structure

```
hosts/
├── common/                    # Shared configuration (all hosts)
│   ├── default.nix            # Central import for all sub-modules
│   ├── boot.nix               # Bootloader (systemd-boot, EFI)
│   ├── locale.nix             # Timezone (Europe/Berlin), i18n, console
│   ├── networking.nix         # NetworkManager, firewall base rules
│   ├── nix-settings.nix       # Flakes, experimental features
│   ├── packages.nix           # System packages (kubectl, helm, sops, etc.)
│   └── users.nix              # User accounts and SSH keys
├── master/
│   ├── default.nix            # Control plane: imports common + k3s/server + services
│   ├── disko-config.nix       # Disk partitioning layout
│   └── hardware-configuration.nix
└── worker-1/
    ├── default.nix            # Worker: imports common + k3s/agent + services
    ├── disko-config.nix
    └── hardware-configuration.nix
```

## Shared Configuration

The `common/` directory replaces the old monolithic `common.nix`. Each concern is in its own file:

- **boot.nix** — systemd-boot, EFI variables
- **locale.nix** — timezone, i18n, console keymap
- **networking.nix** — NetworkManager, firewall (enabled, SSH open)
- **nix-settings.nix** — flakes, nix-command
- **packages.nix** — system-wide packages and KUBECONFIG
- **users.nix** — user accounts (parameterized via `meta.hostname`), SSH keys, openssh

Nix resolves `../common` to `../common/default.nix` automatically.

## Hosts

| Host | Role | Imports |
|------|------|---------|
| **master** | K3s control plane | `common`, `modules/k3s/server.nix`, `modules/services/*` |
| **worker-1** | K3s worker agent | `common`, `modules/k3s/agent.nix`, `modules/services/*` |

## Adding a New Host

1. Create `hosts/worker-X/` with `disko-config.nix` and `hardware-configuration.nix`

2. Create `hosts/worker-X/default.nix`:
   ```nix
   { config, pkgs, meta, ... }:
   {
     imports = [
       ./disko-config.nix
       ./hardware-configuration.nix
       ../common
       ../../modules/k3s/agent.nix
       ../../modules/services/monitoring.nix
       ../../modules/services/storage.nix
     ];

     networking.hostName = "worker-X";
     system.stateVersion = "25.05";
   }
   ```

3. Add the host to `flake.nix`:
   ```nix
   worker-X = lib.mkHost { hostname = "worker-X"; };
   ```

4. Add the host's SSH public key to `secrets/secrets.nix`


# Role-Based Configurations

This directory contains role-based NixOS configurations that can be imported by hosts.

## Roles

- **k3s-server.nix** - K3s control plane (master) configuration
- **k3s-agent.nix** - K3s worker (agent) configuration
- **monitoring.nix** - Node-level monitoring (node_exporter, etc.)
- **common-services.nix** - Services all nodes need (tailscale, etc.)

## Usage

Import roles in your host's `default.nix`:

```nix
{ config, pkgs, meta, ... }:
{
  imports = [
    ../common.nix
    ../../roles/k3s-server.nix
    ../../roles/monitoring.nix
  ];
}
```

## Adding a New Role

1. Create `roles/my-role.nix`
2. Define the role-specific configuration
3. Import it in the appropriate hosts


# NixOS Modules

Reusable NixOS modules for K3s cluster management and node services.

## Structure

```
modules/
├── k3s/
│   ├── common.nix       # Shared K3s config (agenix secret, systemd ordering)
│   ├── server.nix       # K3s control plane (imports common.nix)
│   └── agent.nix        # K3s worker agent (imports common.nix, parameterized serverAddr)
└── services/
    ├── monitoring.nix   # Prometheus node_exporter
    └── storage.nix      # iSCSI + Longhorn prerequisites
```

## K3s Modules

### `k3s/common.nix`

Shared configuration for all K3s nodes:
- Decrypts `k3s-token.age` via agenix
- Systemd dependency ordering (`network-online.target`)
- Graceful shutdown, restart-on-failure

### `k3s/server.nix`

Control plane module:
- Imports `common.nix`
- Enables K3s in `server` role with `clusterInit = true`
- Disables built-in servicelb, traefik, local-storage (managed by Flux instead)
- Opens firewall ports: TCP 6443, 10250; UDP 8472 (Flannel VXLAN)

### `k3s/agent.nix`

Worker module:
- Imports `common.nix`
- Enables K3s in `agent` role
- `serverAddr` defaults to `"https://master:6443"` (overridable via `lib.mkDefault`)
- Opens firewall ports: TCP 10250; UDP 8472

## Service Modules

### `services/monitoring.nix`

Enables Prometheus `node_exporter` on port 9100 with `systemd` and `processes` collectors. Opens firewall automatically via `openFirewall = true`.

### `services/storage.nix`

Longhorn prerequisites:
- `openiscsi` for iSCSI volume management
- Symlinks `/usr/local/bin` for Longhorn compatibility
- Docker log driver configuration

## Usage

Import modules in host `default.nix`:

```nix
imports = [
  ../../modules/k3s/server.nix       # or agent.nix
  ../../modules/services/monitoring.nix
  ../../modules/services/storage.nix
];
```


# modules

Reusable NixOS modules shared across nodes.

## Layout

```
modules/
├── k3s/
│   ├── common.nix    # Shared: agenix token, systemd ordering
│   ├── server.nix    # Control plane role
│   └── agent.nix     # Worker role
└── services/
    ├── monitoring.nix # node_exporter (port 9100)
    └── storage.nix    # openiscsi + Longhorn prerequisites
```

## k3s

| Module | Role | Key config |
|---|---|---|
| `common.nix` | Both | Decrypts `k3s-token.age`, orders after `network-online.target` |
| `server.nix` | Master | `clusterInit = true`, disables built-in servicelb/traefik/local-storage |
| `agent.nix` | Workers | Connects to `https://master:6443` |

## services

`monitoring.nix` — Prometheus `node_exporter` with systemd and process collectors.

`storage.nix` — Enables `openiscsi` and creates the `/usr/local/bin` symlink Longhorn requires.

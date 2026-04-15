# hosts

Per-host NixOS configurations.

## Layout

```
hosts/
├── common/               # Shared config imported by every node
│   ├── boot.nix          # systemd-boot, EFI
│   ├── locale.nix        # Europe/Berlin, i18n
│   ├── networking.nix    # NetworkManager, base firewall
│   ├── nix-settings.nix  # Flakes, experimental features
│   ├── packages.nix      # System packages, KUBECONFIG
│   └── users.nix         # User accounts, SSH keys
└── master/
    ├── default.nix
    ├── disko-config.nix
    └── hardware-configuration.nix
```

Workers are declared inline in `lib/default.nix` via `mkWorker` — they share the same structure but don't need a dedicated directory unless they diverge from the template.

## Adding a Worker

1. Add to `flake.nix`:
   ```nix
   worker-3 = lib.mkWorker { workerId = 3; };
   ```

2. Add the node's SSH host key to `secrets/secrets.nix`.

3. Provision with disko, then:
   ```bash
   nixos-rebuild switch --flake .#worker-3 --target-host root@<ip>
   ```

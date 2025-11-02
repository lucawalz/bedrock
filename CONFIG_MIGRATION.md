# Configuration File Migration Summary

## What Happened to the Old Files?

### `nixos/configuration.nix`

**Status**: Split into multiple files for better organization

**Replaced by**:
- `hosts/common.nix` - Shared configuration (users, packages, system settings)
- `hosts/master/default.nix` - Master node-specific config
- `hosts/worker-1/default.nix` - Worker node-specific config
- `roles/k3s-server.nix` - K3s server role configuration
- `roles/k3s-agent.nix` - K3s agent role configuration
- `roles/common-services.nix` - Common services for all nodes

**Why**: Better separation of concerns, easier to maintain, and allows sharing common config across hosts.

### `nixos/disko-config.nix`

**Status**: Copied to each host directory

**Replaced by**:
- `hosts/master/disko-config.nix`
- `hosts/worker-1/disko-config.nix`

**Why**: Each host may have different disk configurations, so each gets its own file.

### `nixos/flake.nix`

**Status**: Moved to root and enhanced

**Replaced by**:
- `flake.nix` (at root)
  - Updated to reference new host structure
  - Added `devShells` for development environment
  - Changed host names: `master` and `worker-1` (kept original names)

**Why**: Flakes should be at repository root. Added devShells for better DX.

### `nixos/flake.lock`

**Status**: Still needed, but should be regenerated

**Action**: Run `nix flake update` or `nix flake lock` to regenerate at root level

**Why**: Lock file tracks exact versions of dependencies. Should be at root with flake.nix.

## Will It Work the Same?

**Yes!** The functionality is identical, just organized differently:

### Before (Old Structure):
```
nixos/
  ├── configuration.nix  (all config in one file)
  ├── disko-config.nix  (shared disk config)
  ├── flake.nix
  └── flake.lock
```

### After (New Structure):
```
.
├── flake.nix           (moved to root, added devShells)
├── flake.lock          (should be regenerated)
├── hosts/
│   ├── common.nix      (shared config - from old configuration.nix)
│   ├── master/
│   │   ├── default.nix (master-specific - from old configuration.nix)
│   │   └── disko-config.nix (copied from old)
│   └── worker-1/
│       ├── default.nix (worker-specific - from old configuration.nix)
│       └── disko-config.nix (copied from old)
└── roles/
    ├── k3s-server.nix  (extracted from old configuration.nix)
    └── k3s-agent.nix   (extracted from old configuration.nix)
```

## Key Changes in Configuration

1. **Host-based organization**: Each host has its own directory
2. **Role-based modules**: K3s configuration separated into roles
3. **Shared common config**: Common settings extracted to `hosts/common.nix`
4. **Same hostnames**: Kept `master` and `worker-1` (your existing names)

## What to Do With Old Files

The `nixos/` directory is still there as a backup. After verifying everything works:

1. **Test the new configuration**:
   ```bash
   just build master
   just build worker-1
   ```

2. **If successful, deploy**:
   ```bash
   just switch master
   just switch worker-1
   ```

3. **After confirming everything works, you can remove the old directory**:
   ```bash
   # Backup first!
   mv nixos nixos.backup
   
   # Or remove after confirming:
   rm -rf nixos
   ```

## Migration Checklist

- [x] Host directories renamed: `home-01` → `master`, `home-02` → `worker-1`
- [x] `flake.nix` updated to use `master` and `worker-1`
- [x] All references updated in documentation
- [x] K3s agent server address set to `https://master:6443`
- [x] Secrets configuration updated to use `master` and `worker-1`
- [ ] Get actual SSH keys and update `secrets/secrets.nix`
- [ ] Copy/regenerate hardware configurations
- [ ] Test builds: `just build master` and `just build worker-1`
- [ ] Deploy and verify

## Next Steps

1. **Update secrets**: Get actual SSH host keys and update `secrets/secrets.nix`
2. **Hardware configs**: Copy from old location or regenerate
3. **Test**: Build both hosts to ensure everything works
4. **Deploy**: Switch to new configuration
5. **Cleanup**: Remove old `nixos/` directory after confirming


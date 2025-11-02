# Disaster Recovery Guide

## Backup Strategy

### What to Backup

1. **Git Repository** - Already version controlled
2. **Encrypted Secrets** - Safe to backup (encrypted)
3. **Kubernetes Data** - PVCs, etcd data
4. **NixOS System State** - `/nix/store` (optional)

### Repository Backup

The entire repository is in git, so regular backups are automatic if pushed to GitHub/GitLab.

### Secrets Backup

Encrypted secrets can be safely backed up:

```bash
# Backup all secrets
tar -czf secrets-backup-$(date +%Y%m%d).tar.gz secrets/

# Store securely (encrypted drive, cloud storage, etc.)
```

### Kubernetes Data Backup

#### Longhorn Backups

If using Longhorn, configure automatic backups:

```bash
# Create backup target in Longhorn UI
# Or via kubectl
kubectl apply -f longhorn-backup-target.yaml
```

#### etcd Backup (K3s)

```bash
# On master node
sudo k3s etcd-snapshot save

# Snapshot location
ls -la /var/lib/rancher/k3s/server/db/snapshots/
```

### NixOS System Backup

Full system backups (optional):

```bash
# Using rsync
sudo rsync -aAXv --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} / /backup/location/

# Or use disko/zfs snapshots if using ZFS
```

## Recovery Procedures

### Complete Host Rebuild

1. **Boot from NixOS ISO**
2. **Partition and mount disk**
3. **Clone repository**:
   ```bash
   git clone https://github.com/lucawalz/nixos-homelab.git /mnt/etc/nixos/homelab
   ```
4. **Restore secrets** (if backed up separately):
   ```bash
   tar -xzf secrets-backup-*.tar.gz -C /mnt/etc/nixos/homelab/
   ```
5. **Install NixOS**:
   ```bash
   cd /mnt/etc/nixos/homelab
   nixos-install --flake .#master
   ```
6. **Reboot and verify**

### K3s Cluster Recovery

#### Master Node Recovery

1. Rebuild master node (see above)
2. K3s will start with existing data in `/var/lib/rancher/k3s/`
3. Verify cluster:
   ```bash
   kubectl get nodes
   kubectl get pods -A
   ```

#### Worker Node Recovery

1. Rebuild worker node
2. Worker will automatically rejoin cluster (if token is correct)
3. Verify:
   ```bash
   kubectl get nodes
   ```

#### Complete Cluster Recovery

If entire cluster is lost:

1. **Rebuild master node**
2. **Create new K3s token**:
   ```bash
   agenix -e secrets/k3s-token.age
   # Generate new token: openssl rand -hex 32
   ```
3. **Update secrets.nix** with new host keys
4. **Rebuild all nodes**
5. **Bootstrap Flux again**:
   ```bash
   just flux-bootstrap
   ```
6. **Restore PVCs** (if using Longhorn backups):
   - Restore from Longhorn backup target
   - Or restore from external backup

### Kubernetes Data Recovery

#### Restore from Longhorn Backup

1. Access Longhorn UI
2. Navigate to Backups
3. Select backup to restore
4. Create volume from backup
5. Update PVCs to use restored volume

#### Restore etcd Snapshot

```bash
# Copy snapshot to master node
sudo k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/path/to/snapshot
```

### Secrets Recovery

If secrets are lost but repository is intact:

1. **Get host SSH keys** (from machines or backup)
2. **Update secrets.nix** with keys
3. **Re-create secrets**:
   ```bash
   agenix -e secrets/k3s-token.age
   # Enter token content
   ```
4. **Rebuild nodes**

### Git Repository Recovery

If repository is lost but GitHub/GitLab backup exists:

```bash
git clone https://github.com/lucawalz/nixos-homelab.git
cd nixos-homelab
# Restore secrets from separate backup if needed
```

## Prevention

### Regular Backups

- **Automated Git pushes** - Repository is always backed up if pushed
- **Secrets backup** - Weekly backup of encrypted secrets
- **Kubernetes snapshots** - Automated Longhorn backups
- **etcd snapshots** - Scheduled K3s etcd snapshots

### Documentation

- Keep hardware notes (which host is which)
- Document network configuration
- Record important passwords (outside git)

### Testing

- Periodically test recovery procedures
- Verify backups are restorable
- Test secrets decryption on fresh machine

## Emergency Contacts

- GitHub repository: https://github.com/lucawalz/nixos-homelab
- Age keys location: `~/.config/sops/age/keys.txt`
- SSH keys location: `/etc/ssh/ssh_host_ed25519_key.pub`


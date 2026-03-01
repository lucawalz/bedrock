# Disaster Recovery Guide

This guide covers backup strategies and recovery procedures for the NixOS homelab.

See also: [Setup Process](setup-process.md)

## Backup Strategy

### What to Backup

1. **Git Repository** - Already version controlled
2. **Encrypted Secrets** - Safe to backup (encrypted)
3. **Kubernetes Data** - PVCs, etcd data
4. **NixOS System State** - `/nix/store` 

### Repository Backup

The entire repo is in git — automatically backed up when pushed.

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

Full system backups :

```bash
# Using rsync
sudo rsync -aAXv --exclude={"/dev/*","/proc/*","/sys/*","/tmp/*","/run/*","/mnt/*","/media/*","/lost+found"} / /backup/location/

# Or use disko/zfs snapshots if using ZFS
```

## Recovery Procedures

### Complete Host Rebuild with nixos-anywhere

Fastest way to rebuild a host:

```bash
# From your local machine
nixos-anywhere --flake .#master root@TARGET_IP
```

This will:
1. Partition the disk automatically (using disko)
2. Install NixOS with your configuration
3. Deploy agenix secrets
4. Start K3s with the correct token

### Manual Host Rebuild

If nixos-anywhere isn't available:

1. **Boot from NixOS ISO**
2. **Partition and mount disk** (or let disko handle it)
3. **Clone repository**:
   ```bash
   git clone https://github.com/YOUR_USERNAME/nixos-homelab.git /mnt/etc/nixos/homelab
   ```
4. **Install NixOS**:
   ```bash
   cd /mnt/etc/nixos/homelab
   nixos-install --flake .#master
   ```
5. **Reboot and verify**:
   ```bash
   reboot
   # After reboot
   kubectl get nodes
   ```

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

1. **Rebuild master node** (using nixos-anywhere or manual method)
2. **Rebuild worker nodes**
3. **Set up kubectl access** from your local machine:
   ```bash
   scp master@MASTER_IP:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s-config
   sed -i '' 's|https://127.0.0.1:6443|https://MASTER_IP:6443|g' ~/.kube/k3s-config
   export KUBECONFIG=~/.kube/k3s-config
   ```
4. **Bootstrap Flux again**:
   ```bash
   export GITHUB_TOKEN=your_token
   flux bootstrap github \
     --owner=YOUR_USERNAME \
     --repository=nixos-homelab \
     --path=kubernetes/clusters/home \
     --personal
   ```
5. **Wait for infrastructure to deploy** (5-10 minutes):
   ```bash
   flux get helmreleases -A
   ```
6. **Restore PVCs** (if using Longhorn backups):
   - Access Longhorn UI
   - Restore from backup target
   - Or restore from external backup

**Note**: The K3s token is managed by agenix and will be automatically deployed from the encrypted secret in Git.

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

## Recovery Checklist

### Complete Cluster Loss
- [ ] Rebuild master node with nixos-anywhere
- [ ] Rebuild worker nodes
- [ ] Set up kubectl access
- [ ] Bootstrap Flux
- [ ] Wait for infrastructure deployment
- [ ] Restore data from backups
- [ ] Verify all services

### Single Node Loss
- [ ] Rebuild node with nixos-anywhere
- [ ] Verify node joins cluster
- [ ] Check pod redistribution
- [ ] Verify services still accessible

### Data Loss
- [ ] Identify affected PVCs
- [ ] Restore from Longhorn backups
- [ ] Or restore from external backups
- [ ] Verify application data integrity

## Emergency Information

Keep this information in a secure, accessible location:

- **Repository URL**: https://github.com/YOUR_USERNAME/nixos-homelab
- **Age keys location**: `~/.config/sops/age/keys.txt`
- **SSH keys location**: `~/.ssh/id_ed25519*`
- **Important passwords**: Store securely outside of git
- **Network configuration**: Document static IPs, VLANs, etc.
- **Hardware information**: Which physical machine is which hostname

## Regular Maintenance

### Weekly
- [ ] Check backup status
- [ ] Verify certificates are renewing
- [ ] Review monitoring alerts

### Monthly  
- [ ] Test backup restoration
- [ ] Update flake inputs: `nix flake update`
- [ ] Review security logs

### Quarterly
- [ ] Test complete disaster recovery procedure
- [ ] Rotate age keys if needed
- [ ] Update documentation


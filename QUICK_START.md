# Quick Start Guide

This guide covers **migration scenarios** and **advanced deployment methods**. 

**New to this setup?** → Use the **[Complete Setup Guide](docs/complete-setup-guide.md)** instead.

**What this guide covers:**
- Fresh installation with nixos-anywhere (advanced users)
- Migration from existing NixOS systems
- Troubleshooting deployment issues

---

## Method 1: Fresh Installation with nixos-anywhere

### Prerequisites

- Target machine with network access
- SSH access to target machine (or physical access for initial setup)
- Your SSH public key added to the configuration

### Step 1: Prepare Your SSH Keys

Add your SSH public key to `hosts/common.nix`:

```nix
users.users.master = {
  # ... existing config ...
  openssh.authorizedKeys.keys = [
    "ssh-ed25519 YOUR_PUBLIC_KEY_HERE your-email@example.com"
  ];
};
```

### Step 2: Adjust Hardware Configuration

Update the disk device in disko configs if needed:

```nix
# In hosts/master/disko-config.nix and hosts/worker-1/disko-config.nix
device = "/dev/nvme0n1";  # Change to your target disk (e.g., /dev/sda)
```

### Step 3: Create K3s Token Secret

Generate a new K3s token and encrypt it:

```bash
# Generate a random token
openssl rand -hex 32 | agenix -e secrets/k3s-token.age
```

### Step 4: Get Target Machine SSH Keys

If the target machine already has NixOS installed:

```bash
ssh-keyscan -t ed25519 TARGET_IP
```

If it's a fresh machine, you'll need to install NixOS first, then get the keys.

### Step 5: Update secrets.nix

Add the target machine's SSH host key to `secrets/secrets.nix`:

```nix
let
  master = "ssh-ed25519 AAAAC3... root@master";  # From ssh-keyscan
  worker-1 = "ssh-ed25519 AAAAC3... root@worker-1";  # From ssh-keyscan
  luca = "ssh-ed25519 YOUR_KEY_HERE your-email@example.com";
in
{
  "k3s-token.age".publicKeys = [ master worker-1 luca ];
}
```

### Step 6: Install with nixos-anywhere

Install the master node:

```bash
nixos-anywhere --flake .#master root@TARGET_IP
```

Install the worker node:

```bash
nixos-anywhere --flake .#worker-1 root@WORKER_IP
```

### Step 7: Bootstrap Flux

From your local machine, bootstrap Flux to deploy all infrastructure:

```bash
# Set up kubectl access
scp master@MASTER_IP:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s-config
sed -i '' 's|https://127.0.0.1:6443|https://MASTER_IP:6443|g' ~/.kube/k3s-config
export KUBECONFIG=~/.kube/k3s-config

# Test kubectl access
kubectl get nodes

# Bootstrap Flux (requires GitHub personal access token)
export GITHUB_TOKEN=your_github_token
flux bootstrap github \
  --owner=YOUR_GITHUB_USERNAME \
  --repository=nixos-homelab \
  --path=kubernetes/clusters/home \
  --personal
```

### Step 8: Verify Installation

Wait 5-10 minutes for all infrastructure to deploy, then check:

```bash
# Check Flux status
flux get kustomizations -A
flux get helmreleases -A

# Check cluster
kubectl get nodes
kubectl get pods -A

# All HelmReleases should show READY: True
```

**Access services:**
- Traefik: `http://MASTER_IP:30080` or `https://MASTER_IP:30443`
- Grafana: Configure ingress or use port-forward

---

## Method 2: Migration from Existing System

Follow these steps to switch from an old `nixos/` structure to the new organized structure.

### Step 1: Get SSH Host Keys

SSH into both nodes and get their SSH host public keys:

```bash
# From master node
ssh master
cat /etc/ssh/ssh_host_ed25519_key.pub
# Copy the output

# From worker-1 node  
ssh worker-1
cat /etc/ssh/ssh_host_ed25519_key.pub
# Copy the output
```

Or from your local machine:

```bash
ssh-keyscan -t ed25519 master
ssh-keyscan -t ed25519 worker-1
```

### Step 2: Update secrets/secrets.nix

Edit `secrets/secrets.nix` and replace the placeholder keys with the actual keys you got in Step 1:

```nix
let
  master = "ssh-ed25519 AAAAC3...";  # Paste actual key here
  worker-1 = "ssh-ed25519 AAAAC3...";  # Paste actual key here
  
  luca = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHoKFFTFmJR1CSAq55TwXHbUPTxSK847qZL0W6r/ZUV9 luca@macbook";
in
{
  "k3s-token.age".publicKeys = [ master worker-1 luca ];
}
```

### Step 3: Create/Update K3s Token Secret

If you already have a K3s cluster running, get the existing token:

```bash
# SSH into master node
ssh master
sudo cat /var/lib/rancher/k3s/server/node-token
```

Then create the encrypted secret:

```bash
# On your local machine, in the repo root
echo "YOUR_K3S_TOKEN_HERE" | agenix -e secrets/k3s-token.age
```

Or if you're setting up a new cluster:

```bash
# Generate a random token
openssl rand -hex 32 | agenix -e secrets/k3s-token.age
```

### Step 4: Copy Hardware Configurations (If Needed)

If you have existing hardware configs from the old `nixos/` directory:

```bash
# Check if you have hardware-specific config in old directory
# If yes, copy them:
cp nixos/hardware-configuration.nix hosts/master/hardware-configuration.nix
cp nixos/hardware-configuration.nix hosts/worker-1/hardware-configuration.nix  # Adjust if different
```

**OR** regenerate them on each node:

```bash
# On master node
ssh master
sudo nixos-generate-config --show-hardware-config > /tmp/hw-config.nix
# Copy /tmp/hw-config.nix content to hosts/master/hardware-configuration.nix

# On worker-1 node
ssh worker-1
sudo nixos-generate-config --show-hardware-config > /tmp/hw-config.nix
# Copy /tmp/hw-config.nix content to hosts/worker-1/hardware-configuration.nix
```

### Step 5: Clone Repository on Nodes (If Not Already There)

SSH into each node and make sure the repo is there:

```bash
# On master node
ssh master
cd /etc/nixos
# If repo exists, update it:
git pull
# If not, clone it:
# git clone https://github.com/lucawalz/nixos-homelab.git .

# On worker-1 node
ssh worker-1
cd /etc/nixos
git pull  # or clone if needed
```

### Step 6: Test Build

Test the build before deploying:

```bash
# On master node
ssh master
cd /etc/nixos
sudo nixos-rebuild build --flake .#master

# On worker-1 node
ssh worker-1
cd /etc/nixos
sudo nixos-rebuild build --flake .#worker-1
```

**Or from your local machine** (if repo is synced):

```bash
# Make sure you have the repo on your machine
just build master
just build worker-1
```

### Step 7: Deploy to Master Node

```bash
# SSH into master
ssh master
cd /etc/nixos
sudo nixos-rebuild switch --flake .#master
```

**Or from your local machine:**

```bash
just switch master
```

Wait for it to complete successfully.

### Step 8: Deploy to Worker-1 Node

```bash
# SSH into worker-1
ssh worker-1
cd /etc/nixos
sudo nixos-rebuild switch --flake .#worker-1
```

**Or from your local machine:**

```bash
just switch worker-1
```

### Step 9: Verify Everything Works

### Check NixOS is running correctly:

```bash
# On both nodes
systemctl status k3s  # or k3s-agent on worker
hostname
```

### Check K3s cluster:

```bash
# On master node
kubectl get nodes
kubectl cluster-info
```

You should see both `master` and `worker-1` nodes.

### Check secrets are decrypting:

```bash
# On master node
sudo cat /run/agenix/k3s-token
# Should show your K3s token (not encrypted)
```

### Step 10: Clean Up (Optional)

Once everything is working:

```bash
# Remove old nixos directory
rm -rf nixos/
```

---

## Troubleshooting (Both Methods)

### Build fails with "cannot decrypt secret"

- Verify SSH keys in `secrets/secrets.nix` match the actual host keys
- Make sure you used `agenix -e secrets/k3s-token.age` to create the secret

### K3s agent can't join

- Verify `roles/k3s-agent.nix` has correct `serverAddr`
- Check firewall allows port 6443
- Verify K3s token is the same for both nodes

### Hardware issues

- Make sure `hardware-configuration.nix` is correct for each host
- Regenerate if needed with `nixos-generate-config`

### Import errors

- Verify all file paths are correct
- Check that `disko-config.nix` exists in each host directory

## Next Steps After Installation

1. **Configure DNS** for `syslabs.dev`:
   - Point your domain/subdomains to your public IP
   - See `docs/dns-setup.md` for details

2. **Set up ingress for services**:
   - Traefik is accessible on NodePort 30080/30443
   - Configure ingress resources for your applications
   - Let's Encrypt certificates will be issued automatically

3. **Access monitoring**:
   ```bash
   # Get Grafana password
   kubectl get secret -n monitoring kube-prometheus-stack-grafana \
     -o jsonpath="{.data.admin-password}" | base64 -d
   
   # Port-forward to access
   kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
   ```

4. **Deploy applications**:
   - Add your apps to `kubernetes/clusters/home/apps/`
   - Commit and push - Flux will deploy automatically

5. **Set up SOPS for Kubernetes secrets** (optional):
   - See `docs/secrets-management.md` for SOPS setup


### nixos-anywhere specific issues

- **Disk device not found**: Update `device = "/dev/nvme0n1"` in disko configs to match your target hardware
- **SSH connection fails**: Ensure target machine is accessible and has SSH enabled
- **Permission denied**: Make sure your SSH key is properly configured in the target user account
- **Disko partitioning fails**: Check if target disk is already in use or has existing partitions that need to be cleared

### Installation Tips

- **Test locally first**: Use `nixos-rebuild build --flake .#master` to test configuration before deploying
- **Check hardware**: Verify disk device names match your target hardware (`lsblk` on target machine)
- **Network configuration**: Adjust static IP settings in host configs if needed
- **Backup important data**: nixos-anywhere will wipe the target disk completely
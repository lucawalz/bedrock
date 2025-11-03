# Complete Setup Guide

This guide will take you from zero to a fully functional NixOS homelab with K3s and Flux GitOps. Follow these steps in order for the best experience.

## What You'll Build

By the end of this guide, you'll have:
- Scalable K3s cluster (starting with master + worker, easily expandable) running on NixOS
- Flux CD for GitOps deployment
- Longhorn distributed storage
- Traefik ingress with automatic SSL certificates
- Prometheus + Grafana monitoring stack
- Encrypted secrets management with agenix and SOPS

**Time estimate**: 45-60 minutes for first-time setup (2-node cluster)

**Scalability**: The architecture supports adding unlimited worker nodes - see [Adding New Hosts](nixos-setup.md#adding-a-new-host) for expansion instructions.

## Prerequisites

Before starting, ensure you have:
- **At least 2 physical machines or VMs** with network access (master + 1 worker minimum)
- **SSH access** to all machines (or physical console access)
- **GitHub account** for GitOps repository
- **Domain name** (optional, for external access) - this guide uses `syslabs.dev`

**Note**: This guide covers setting up a 2-node cluster, but you can easily add more worker nodes later using the same process.

---

## Step 1: Prepare Your Environment

### 1.1 Fork or Clone Repository

```bash
# Option A: Fork the repository on GitHub, then clone your fork
git clone https://github.com/YOUR_USERNAME/nixos-homelab.git
cd nixos-homelab

# Option B: Clone directly (you'll need to change the remote later)
git clone https://github.com/lucawalz/nixos-homelab.git
cd nixos-homelab
```

### 1.2 Set Up Development Environment

```bash
# If you have Nix installed (recommended)
nix develop

# Or install tools manually
# - age: for secrets encryption
# - agenix: for NixOS secrets management  
# - flux: for Kubernetes GitOps
# - kubectl: for Kubernetes management
```

### 1.3 Generate Age Keys (for secrets)

```bash
# Create age key for secrets encryption
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt

# Display your public key (you'll need this later)
cat ~/.config/sops/age/keys.txt | grep "# public key:"
```

**Save this public key** - you'll need it for SOPS configuration later.

---

## Step 2: Configure Your Setup

### 2.1 Update SSH Keys

Add your SSH public key to allow access to the machines:

```bash
# Generate SSH key if you don't have one
ssh-keygen -t ed25519 -C "your-email@example.com"

# Display your public key
cat ~/.ssh/id_ed25519.pub
```

Edit `hosts/common.nix` and add your SSH key:

```nix
users.users.master = {
  # ... existing config ...
  openssh.authorizedKeys.keys = [
    "ssh-ed25519 YOUR_PUBLIC_KEY_HERE your-email@example.com"
  ];
};
```

### 2.2 Configure Hardware Settings

Update disk device names in the disko configurations if needed:

```bash
# Check your target machines' disk layout
lsblk  # Run this on your target machines

# Update these files if your disks are different:
# hosts/master/disko-config.nix
# hosts/worker-1/disko-config.nix
```

Edit the device line in both files:
```nix
device = "/dev/nvme0n1";  # Change to your actual disk (e.g., /dev/sda)
```

### 2.3 Configure Network Settings (Optional)

If you want static IP addresses, edit the host configurations:

```nix
# In hosts/master/default.nix
networking = {
  hostName = "master";
  interfaces.eth0.ipv4.addresses = [{
    address = "192.168.1.10";
    prefixLength = 24;
  }];
  defaultGateway = "192.168.1.1";
  nameservers = [ "1.1.1.1" "8.8.8.8" ];
};
```

---

## Step 3: Install NixOS with nixos-anywhere

### 3.1 Prepare Target Machines

Boot both target machines from a NixOS ISO or ensure they have network-bootable NixOS environments.

### 3.2 Create K3s Token Secret

Generate a secure token for K3s cluster communication:

```bash
# Generate a random token
openssl rand -hex 32 | agenix -e secrets/k3s-token.age
```

### 3.3 Get Target Machine SSH Keys

For each target machine, get its SSH host key:

```bash
# Replace TARGET_IP with your machine's IP
ssh-keyscan -t ed25519 TARGET_IP_MASTER
ssh-keyscan -t ed25519 TARGET_IP_WORKER
```

### 3.4 Update Secrets Configuration

Edit `secrets/secrets.nix` with the SSH keys you just collected:

```nix
let
  # Replace these with the actual keys from ssh-keyscan
  master = "ssh-ed25519 AAAAC3... root@master";
  worker-1 = "ssh-ed25519 AAAAC3... root@worker-1";
  
  # Your personal key (for managing secrets)
  yourname = "ssh-ed25519 YOUR_KEY_HERE your-email@example.com";
in
{
  "k3s-token.age".publicKeys = [ master worker-1 yourname ];
}
```

### 3.5 Install Master Node

```bash
# Install NixOS on the master node
nixos-anywhere --flake .#master root@TARGET_IP_MASTER
```

This will:
- Partition the disk automatically
- Install NixOS with your configuration
- Set up K3s master node
- Deploy encrypted secrets

**Wait for completion** (usually 10-15 minutes).

### 3.6 Install Worker Node

```bash
# Install NixOS on the worker node  
nixos-anywhere --flake .#worker-1 root@TARGET_IP_WORKER
```

**Wait for completion** before proceeding.

---

## Step 4: Verify NixOS Installation

### 4.1 Test SSH Access

```bash
# Test access to both nodes
ssh master@TARGET_IP_MASTER
ssh master@TARGET_IP_WORKER
```

### 4.2 Verify K3s Cluster

```bash
# On the master node
ssh master@TARGET_IP_MASTER
kubectl get nodes

# You should see both master and worker-1 nodes in Ready state
```

### 4.3 Check Secrets Decryption

```bash
# On master node, verify the K3s token is decrypted
ssh master@TARGET_IP_MASTER
sudo cat /run/agenix/k3s-token
# Should show your token (not encrypted content)
```

---

## Step 5: Set Up Kubernetes Access

### 5.1 Copy Kubeconfig

```bash
# Copy the K3s kubeconfig to your local machine
scp master@TARGET_IP_MASTER:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s-config

# Update the server address
sed -i 's|https://127.0.0.1:6443|https://TARGET_IP_MASTER:6443|g' ~/.kube/k3s-config

# Set as your active kubeconfig
export KUBECONFIG=~/.kube/k3s-config
```

### 5.2 Test Kubernetes Access

```bash
# Test kubectl access
kubectl get nodes
kubectl get pods -A

# You should see system pods running
```

---

## Step 6: Bootstrap Flux GitOps

### 6.1 Create GitHub Personal Access Token

1. Go to GitHub Settings > Developer settings > Personal access tokens
2. Create a new token with `repo` permissions
3. Save the token securely

### 6.2 Bootstrap Flux

```bash
# Set your GitHub token
export GITHUB_TOKEN=your_github_token_here

# Bootstrap Flux (replace with your GitHub username)
flux bootstrap github \
  --owner=YOUR_GITHUB_USERNAME \
  --repository=nixos-homelab \
  --path=kubernetes/clusters/home \
  --personal
```

This will:
- Install Flux components in your cluster
- Create a deploy key in your GitHub repository
- Set up automatic synchronization

### 6.3 Wait for Infrastructure Deployment

```bash
# Monitor Flux deployment (this may take 10-15 minutes)
watch flux get kustomizations -A

# Check HelmReleases
watch flux get helmreleases -A

# All should eventually show READY: True
```

---

## Step 7: Configure DNS and Certificates

### 7.1 Update Domain Configuration

If you have a domain, update the certificate issuer email:

```bash
# Edit the cert-manager configuration
# Find and update email addresses in:
# kubernetes/clusters/home/infrastructure/cert-manager/
```

### 7.2 Configure DNS Records

Point your domain to your public IP:

```
# DNS A records
traefik.syslabs.dev    -> YOUR_PUBLIC_IP
grafana.syslabs.dev    -> YOUR_PUBLIC_IP
longhorn.syslabs.dev   -> YOUR_PUBLIC_IP
*.syslabs.dev          -> YOUR_PUBLIC_IP  (wildcard)
```

### 7.3 Configure Port Forwarding

Set up port forwarding on your router:
- Port 80 -> master node IP:30080
- Port 443 -> master node IP:30443

---

## Step 8: Verify Complete Installation

### 8.1 Check All Components

```bash
# Check cluster status
kubectl get nodes
kubectl get pods -A

# Check Flux status
flux get kustomizations -A
flux get helmreleases -A

# Check storage
kubectl get pv,pvc -A
```

### 8.2 Access Services

Test access to your services:

```bash
# Traefik dashboard (if domain configured)
curl -k https://traefik.syslabs.dev

# Or via NodePort
curl http://TARGET_IP_MASTER:30080
```

### 8.3 Get Grafana Password

```bash
# Get the Grafana admin password
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d
echo  # Add newline
```

---

## Step 9: Next Steps

### 9.1 Deploy Your First Application

Create a simple application in `kubernetes/clusters/home/apps/`:

```yaml
# kubernetes/clusters/home/apps/web/nginx/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
  namespace: web
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      containers:
      - name: nginx
        image: nginx:latest
        ports:
        - containerPort: 80
```

Add it to the kustomization and commit - Flux will deploy it automatically.

### 9.2 Set Up Monitoring

Access Grafana at `https://grafana.syslabs.dev` (or via port-forward) and explore the pre-configured dashboards.

### 9.3 Add More Worker Nodes (Optional)

Your cluster can be easily expanded by adding more worker nodes:

1. **Prepare additional machines** with NixOS
2. **Follow the worker node installation process** from Step 3.6
3. **See detailed instructions** in [Adding New Hosts](nixos-setup.md#adding-a-new-host)

Each additional worker increases:
- Compute capacity for applications
- Storage capacity for Longhorn
- High availability and fault tolerance

### 9.4 Configure Backups

Set up regular backups of your configurations and data. See the [Disaster Recovery Guide](disaster-recovery.md) for details.

---

## Troubleshooting

### nixos-anywhere Issues

**Disk not found**: Update device names in `hosts/*/disko-config.nix`
**SSH connection fails**: Verify target machine network and SSH access
**Build fails**: Check syntax in configuration files

### Secrets Issues

**Cannot decrypt**: Verify SSH host keys in `secrets/secrets.nix` match actual machines
**Wrong keys**: Re-run `ssh-keyscan` and update `secrets/secrets.nix`

### Kubernetes Issues

**Nodes not ready**: Check K3s service status with `systemctl status k3s`
**Flux not syncing**: Verify GitHub repository access and webhook configuration
**Pods not starting**: Check resource limits and storage availability

### Network Issues

**Services not accessible**: Verify port forwarding and DNS configuration
**Certificates not issued**: Check cert-manager logs and DNS propagation

---

## Getting Help

- **NixOS issues**: See [NixOS Setup Guide](nixos-setup.md)
- **Kubernetes issues**: See [Kubernetes Setup Guide](kubernetes-setup.md)  
- **Secrets issues**: See [Secrets Management Guide](secrets-management.md)
- **DNS issues**: See [DNS Setup Guide](dns-setup.md)

**Congratulations!** You now have a fully functional NixOS homelab with GitOps deployment. Your infrastructure is declarative, reproducible, and automatically managed.
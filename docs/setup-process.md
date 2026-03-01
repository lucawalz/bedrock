# Setup Process

Step-by-step process for provisioning a NixOS + K3s homelab cluster from scratch.

## End Result

- Scalable K3s cluster (master + workers) on NixOS
- Flux CD for GitOps deployment
- Longhorn distributed storage
- Traefik ingress with automatic SSL certificates
- Prometheus + Grafana monitoring stack
- Encrypted secrets via agenix (NixOS) and SOPS (Kubernetes)

**Time**: ~45-60 minutes for a 2-node cluster

**Scaling**: Add more workers later using the same process — see [hosts/README](../hosts/README.md).

## Prerequisites

- At least 2 physical machines or VMs with network access (master + 1 worker)
- SSH access to all machines (or physical console access)
- GitHub account with personal access token (`repo` scope)
- Domain name (optional) — currently using `syslabs.dev`

---

## Step 1: Environment Setup

### 1.1 Dev Shell

```bash
cd nixos-homelab
nix develop  # provides age, agenix, flux, kubectl
```

### 1.2 Age Keys (for SOPS)

```bash
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt
cat ~/.config/sops/age/keys.txt | grep "# public key:"  # save this
```

---

## Step 2: Configuration

### 2.1 SSH Keys

Add SSH public key to `hosts/common/users.nix`:

```nix
openssh.authorizedKeys.keys = [
  "ssh-ed25519 AAAA... email@example.com"
];
```

### 2.2 Disk Layout

Verify/update disk device names in disko configs:

```bash
lsblk  # on target machines
# Update hosts/master/disko-config.nix and hosts/worker-1/disko-config.nix
```

```nix
device = "/dev/nvme0n1";  # or /dev/sda
```

### 2.3 Static IPs (Optional)

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

## Step 3: NixOS Installation (nixos-anywhere)

### 3.1 Boot target machines from NixOS ISO

### 3.2 Create K3s Token

```bash
openssl rand -hex 32 | agenix -e secrets/k3s-token.age
```

### 3.3 Collect SSH Host Keys

```bash
ssh-keyscan -t ed25519 TARGET_IP_MASTER
ssh-keyscan -t ed25519 TARGET_IP_WORKER
```

### 3.4 Update `secrets/secrets.nix`

```nix
let
  master = "ssh-ed25519 AAAAC3... root@master";
  worker-1 = "ssh-ed25519 AAAAC3... root@worker-1";
  luca = "ssh-ed25519 ... luca@...";
in
{
  "k3s-token.age".publicKeys = [ master worker-1 luca ];
}
```

### 3.5 Install Nodes

```bash
# Master (~10-15 min)
nixos-anywhere --flake .#master root@TARGET_IP_MASTER

# Worker (after master completes)
nixos-anywhere --flake .#worker-1 root@TARGET_IP_WORKER
```

This partitions disks (disko), installs NixOS, deploys agenix secrets, and starts K3s.

---

## Step 4: Verify Installation

```bash
ssh master@TARGET_IP_MASTER
kubectl get nodes           # both nodes should be Ready
sudo cat /run/agenix/k3s-token  # verify decryption works
```

---

## Step 5: Local Kubernetes Access

```bash
scp master@TARGET_IP_MASTER:/etc/rancher/k3s/k3s.yaml ~/.kube/k3s-config
sed -i 's|https://127.0.0.1:6443|https://TARGET_IP_MASTER:6443|g' ~/.kube/k3s-config
export KUBECONFIG=~/.kube/k3s-config
kubectl get nodes && kubectl get pods -A
```

---

## Step 6: Flux Bootstrap

```bash
export GITHUB_TOKEN=<token>
flux bootstrap github \
  --owner=lucawalz \
  --repository=nixos-homelab \
  --path=kubernetes/clusters/home \
  --personal
```

Wait for infrastructure (~10-15 min):

```bash
watch flux get kustomizations -A    # all should show READY: True
watch flux get helmreleases -A
```

---

## Step 7: DNS & Certificates

Update cert-manager issuer email in `infrastructure/cert-manager/`.

DNS records (or use Cloudflare tunnel — see [dns-setup.md](dns-setup.md)):

```
*.syslabs.dev    →  PUBLIC_IP  (wildcard)
```

Router port forwarding (if not using tunnel):
- Port 80 → master:30080
- Port 443 → master:30443

---

## Step 8: Verification

```bash
kubectl get nodes
kubectl get pods -A
flux get kustomizations -A
flux get helmreleases -A
kubectl get pv,pvc -A

# Grafana password
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d && echo
```

---

## Next Steps

- Add worker nodes → [hosts/README](../hosts/README.md)
- Configure backups → [disaster-recovery.md](disaster-recovery.md)
- Grafana dashboards at `https://grafana.syslabs.dev`

---

## Troubleshooting

| Problem | Fix |
|---------|-----|
| Disk not found | Update device names in `hosts/*/disko-config.nix` |
| SSH fails | Verify network, check firewall |
| Cannot decrypt secrets | Verify SSH host keys in `secrets/secrets.nix` match actual machines |
| Nodes not ready | `systemctl status k3s` on the node |
| Flux not syncing | `flux get kustomizations` — check errors |
| Certificates not issued | Check cert-manager logs, DNS propagation |

See also: [kubernetes-setup.md](kubernetes-setup.md), [secrets-management.md](secrets-management.md), [dns-setup.md](dns-setup.md)
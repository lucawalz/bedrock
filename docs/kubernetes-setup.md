# Kubernetes Setup with K3s and Flux

## Architecture

- **master**: K3s control plane (server/master)
- **worker-1**: K3s worker node (agent)
- **Flux CD**: GitOps for Kubernetes manifests

## K3s Cluster Setup

### Initial Setup

K3s is configured via NixOS roles:
- `roles/k3s-server.nix` - Control plane configuration
- `roles/k3s-agent.nix` - Worker node configuration

The cluster token is managed via agenix and stored in `secrets/k3s-token.age`.

### Joining Nodes

1. Ensure the K3s token is the same for all nodes (managed via agenix)
2. Worker nodes automatically join when configured with:
   ```nix
   services.k3s = {
     enable = true;
     role = "agent";
     serverAddr = "https://master:6443";
     tokenFile = config.age.secrets.k3s-token.path;
   };
   ```

### Verify Cluster

```bash
# From master node
kubectl get nodes
kubectl cluster-info
```

## Flux CD Bootstrap

### Prerequisites

- GitHub repository access
- kubectl access to the cluster
- Flux CLI installed (included in devShell)

### Bootstrap Flux

One-time setup from your machine:

```bash
# Make sure kubectl is configured
export KUBECONFIG=/path/to/k3s/kubeconfig.yaml

# Bootstrap Flux
just flux-bootstrap

# Or manually:
flux bootstrap github \
  --owner=lucawalz \
  --repository=nixos-homelab \
  --path=kubernetes/clusters/home \
  --personal
```

This will:
1. Install Flux controllers in the cluster
2. Create a GitRepository pointing to this repo
3. Create a Kustomization that watches `kubernetes/clusters/home/`

### Verify Flux

```bash
just flux-check
# or
flux get all -A
```

All resources should show "Ready" status.

## Deployment Order

Flux automatically deploys resources in dependency order:

1. **Sources** - Helm repositories
2. **Config** - Cluster configuration
3. **Infrastructure**:
   - Storage (Longhorn)
   - Networking (Traefik, cert-manager)
   - Monitoring (Prometheus/Grafana)
4. **Apps** - Applications
5. **Secrets** - Encrypted secrets

## Adding Applications

1. Create app directory: `kubernetes/clusters/home/apps/category/app-name/`
2. Create manifests (HelmRelease, Deployment, etc.)
3. Add to parent `kustomization.yaml`
4. Commit and push - Flux will deploy automatically

Example: Adding Glance dashboard

```bash
mkdir -p kubernetes/clusters/home/apps/dashboards/glance
# Create namespace.yaml, deployment.yaml, service.yaml, ingress.yaml
# Add to apps/dashboards/kustomization.yaml
```

## Troubleshooting

### Flux not syncing

```bash
# Check Flux status
flux get sources git
flux get kustomizations

# Manual reconciliation
flux reconcile kustomization -A
```

### Pods not starting

```bash
# Check pod logs
kubectl logs -n <namespace> <pod-name>

# Check events
kubectl describe pod -n <namespace> <pod-name>

# Check PVCs (if using storage)
kubectl get pvc -A
```

### HelmRelease stuck

```bash
# Check HelmRelease status
flux get helmreleases -A

# View HelmRelease details
kubectl describe helmrelease -n <namespace> <name>
```

### Storage issues (Longhorn)

```bash
# Check Longhorn status
kubectl get pods -n longhorn-system

# Access Longhorn UI
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
```

## Monitoring

### Access Grafana

```bash
# Get Grafana admin password
kubectl get secret -n monitoring kube-prometheus-stack-grafana -o jsonpath="{.data.admin-password}" | base64 -d

# Port-forward
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

Visit `http://localhost:3000` (admin / password from above)

### Access Prometheus

```bash
kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090
```

Visit `http://localhost:9090`


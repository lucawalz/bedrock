# Kubernetes & Flux Reference

This document covers K3s cluster management and Flux GitOps configuration.

**For complete setup instructions, see the [Complete Setup Guide](complete-setup-guide.md).**

## Overview

The Kubernetes setup includes:
- **K3s** - Lightweight Kubernetes distribution
- **Flux CD** - GitOps continuous deployment
- **Longhorn** - Distributed block storage
- **Traefik** - Ingress controller with automatic SSL
- **cert-manager** - Certificate management
- **Prometheus/Grafana** - Monitoring stack

## K3s Configuration

### Master Node Configuration

The master node runs the K3s server with embedded etcd:

```nix
# roles/k3s-server.nix
services.k3s = {
  enable = true;
  role = "server";
  tokenFile = config.age.secrets.k3s-token.path;
  extraFlags = toString [
    "--cluster-init"
    "--disable=traefik"  # We use our own Traefik
    "--disable=servicelb"
    "--disable=local-storage"
    "--write-kubeconfig-mode=644"
    "--kube-controller-manager-arg=bind-address=0.0.0.0"
    "--kube-proxy-arg=metrics-bind-address=0.0.0.0"
    "--kube-scheduler-arg=bind-address=0.0.0.0"
  ];
};
```

### Worker Node Configuration

Worker nodes join the cluster as agents:

```nix
# roles/k3s-agent.nix
services.k3s = {
  enable = true;
  role = "agent";
  tokenFile = config.age.secrets.k3s-token.path;
  serverAddr = "https://master:6443";
  extraFlags = toString [
    "--kube-proxy-arg=metrics-bind-address=0.0.0.0"
  ];
};
```

### Cluster Networking

K3s uses Flannel for pod networking by default. The configuration allows:
- Pod-to-pod communication across nodes
- Service discovery via CoreDNS
- Load balancing with kube-proxy

## Flux GitOps

### Bootstrap Process

Flux is bootstrapped once to set up the GitOps workflow:

```bash
flux bootstrap github \
  --owner=YOUR_GITHUB_USERNAME \
  --repository=nixos-homelab \
  --path=kubernetes/clusters/home \
  --personal
```

This creates:
- Flux system components in the cluster
- Deploy key in your GitHub repository
- Webhook for automatic synchronization

### Repository Structure

```
kubernetes/clusters/home/
├── kustomization.yaml          # Main Flux entry point
├── flux-system/               # Flux components (auto-generated)
├── config/                    # Cluster-wide configuration
├── infrastructure/            # Core infrastructure components
├── apps/                      # Applications
└── sources/                   # Git/Helm repositories
```

### Kustomization Hierarchy

```yaml
# kubernetes/clusters/home/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ./config
  - ./infrastructure
  - ./apps
```

Each directory has its own kustomization that Flux monitors.

## Infrastructure Components

### Storage with Longhorn

Longhorn provides distributed block storage:

```yaml
# kubernetes/clusters/home/infrastructure/longhorn/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: longhorn
  namespace: longhorn-system
spec:
  chart:
    spec:
      chart: longhorn
      sourceRef:
        kind: HelmRepository
        name: longhorn
        namespace: flux-system
  values:
    defaultSettings:
      defaultReplicaCount: 2
      defaultDataPath: /var/lib/longhorn
```

### Ingress with Traefik

Traefik handles ingress and automatic SSL:

```yaml
# kubernetes/clusters/home/infrastructure/traefik/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: traefik
  namespace: traefik
spec:
  chart:
    spec:
      chart: traefik
      sourceRef:
        kind: HelmRepository
        name: traefik
        namespace: flux-system
  values:
    service:
      type: NodePort
      spec:
        ports:
          web:
            nodePort: 30080
          websecure:
            nodePort: 30443
```

### Certificate Management

cert-manager automatically issues SSL certificates:

```yaml
# kubernetes/clusters/home/infrastructure/cert-manager/cluster-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: your-email@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - http01:
        ingress:
          class: traefik
```

### Monitoring Stack

Prometheus and Grafana for observability:

```yaml
# kubernetes/clusters/home/infrastructure/monitoring/kube-prometheus-stack.yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: kube-prometheus-stack
  namespace: monitoring
spec:
  chart:
    spec:
      chart: kube-prometheus-stack
      sourceRef:
        kind: HelmRepository
        name: prometheus-community
        namespace: flux-system
  values:
    grafana:
      ingress:
        enabled: true
        hosts:
          - grafana.syslabs.dev
        tls:
          - secretName: grafana-tls
            hosts:
              - grafana.syslabs.dev
```

## Application Deployment

### Creating a New Application

1. **Create application directory**:
   ```bash
   mkdir -p kubernetes/clusters/home/apps/web/my-app
   ```

2. **Create deployment manifest**:
   ```yaml
   # kubernetes/clusters/home/apps/web/my-app/deployment.yaml
   apiVersion: apps/v1
   kind: Deployment
   metadata:
     name: my-app
     namespace: web
   spec:
     replicas: 2
     selector:
       matchLabels:
         app: my-app
     template:
       metadata:
         labels:
           app: my-app
       spec:
         containers:
         - name: my-app
           image: nginx:latest
           ports:
           - containerPort: 80
   ```

3. **Create service**:
   ```yaml
   # kubernetes/clusters/home/apps/web/my-app/service.yaml
   apiVersion: v1
   kind: Service
   metadata:
     name: my-app
     namespace: web
   spec:
     selector:
       app: my-app
     ports:
     - port: 80
       targetPort: 80
   ```

4. **Create ingress**:
   ```yaml
   # kubernetes/clusters/home/apps/web/my-app/ingress.yaml
   apiVersion: networking.k8s.io/v1
   kind: Ingress
   metadata:
     name: my-app
     namespace: web
     annotations:
       cert-manager.io/cluster-issuer: letsencrypt-prod
   spec:
     tls:
     - hosts:
       - my-app.syslabs.dev
       secretName: my-app-tls
     rules:
     - host: my-app.syslabs.dev
       http:
         paths:
         - path: /
           pathType: Prefix
           backend:
             service:
               name: my-app
               port:
                 number: 80
   ```

5. **Create kustomization**:
   ```yaml
   # kubernetes/clusters/home/apps/web/my-app/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - namespace.yaml
     - deployment.yaml
     - service.yaml
     - ingress.yaml
   ```

6. **Add to parent kustomization**:
   ```yaml
   # kubernetes/clusters/home/apps/web/kustomization.yaml
   apiVersion: kustomize.config.k8s.io/v1beta1
   kind: Kustomization
   resources:
     - my-app
   ```

### Using Helm Charts

For complex applications, use HelmRelease:

```yaml
# kubernetes/clusters/home/apps/databases/postgresql/helmrelease.yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: postgresql
  namespace: databases
spec:
  interval: 15m
  chart:
    spec:
      chart: postgresql
      version: "12.x.x"
      sourceRef:
        kind: HelmRepository
        name: bitnami
        namespace: flux-system
  values:
    auth:
      postgresPassword: "secure-password"
    primary:
      persistence:
        enabled: true
        storageClass: longhorn
        size: 10Gi
```

## Secrets Management

### SOPS for Kubernetes Secrets

Kubernetes secrets are encrypted with SOPS:

```yaml
# kubernetes/clusters/home/apps/web/my-app/secret.sops.yaml
apiVersion: v1
kind: Secret
metadata:
    name: my-app-secret
    namespace: web
type: Opaque
data:
    password: ENC[AES256_GCM,data:...,tag:...,type:str]
```

### Creating SOPS Secrets

```bash
# Create .sops.yaml configuration
cat > .sops.yaml << EOF
creation_rules:
  - path_regex: kubernetes/.*\.sops\.yaml$
    age: age1234567890abcdef...
EOF

# Create encrypted secret
kubectl create secret generic my-secret \
  --from-literal=password=mysecret \
  --dry-run=client -o yaml | \
  sops --encrypt --input-type=yaml --output-type=yaml \
  /dev/stdin > secret.sops.yaml
```

## Monitoring and Observability

### Accessing Grafana

```bash
# Get Grafana admin password
kubectl get secret -n monitoring kube-prometheus-stack-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d

# Port-forward to access locally
kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80
```

### Custom Dashboards

Add custom Grafana dashboards:

```yaml
# kubernetes/clusters/home/infrastructure/monitoring/dashboards/my-dashboard.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: my-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"
data:
  my-dashboard.json: |
    {
      "dashboard": {
        "title": "My Custom Dashboard",
        "panels": [...]
      }
    }
```

### Prometheus Rules

Create custom alerting rules:

```yaml
# kubernetes/clusters/home/infrastructure/monitoring/rules/my-rules.yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: my-rules
  namespace: monitoring
spec:
  groups:
  - name: my-app.rules
    rules:
    - alert: MyAppDown
      expr: up{job="my-app"} == 0
      for: 5m
      labels:
        severity: critical
      annotations:
        summary: "My app is down"
```

## Troubleshooting

### Flux Issues

**Check Flux status**:
```bash
flux get kustomizations -A
flux get helmreleases -A
flux get sources git -A
```

**Force reconciliation**:
```bash
flux reconcile kustomization flux-system
flux reconcile helmrelease -n infrastructure traefik
```

**Check Flux logs**:
```bash
kubectl logs -n flux-system deployment/source-controller
kubectl logs -n flux-system deployment/kustomize-controller
kubectl logs -n flux-system deployment/helm-controller
```

### Application Issues

**Pod not starting**:
```bash
kubectl describe pod -n namespace pod-name
kubectl logs -n namespace pod-name
```

**Service not accessible**:
```bash
kubectl get svc -n namespace
kubectl get endpoints -n namespace
```

**Ingress issues**:
```bash
kubectl describe ingress -n namespace ingress-name
kubectl logs -n traefik deployment/traefik
```

### Storage Issues

**PVC not binding**:
```bash
kubectl get pv,pvc -A
kubectl describe pvc -n namespace pvc-name
```

**Longhorn issues**:
```bash
kubectl get pods -n longhorn-system
kubectl logs -n longhorn-system deployment/longhorn-manager
```

### Certificate Issues

**Certificate not issued**:
```bash
kubectl get certificates -A
kubectl describe certificate -n namespace cert-name
kubectl logs -n cert-manager deployment/cert-manager
```

**Check ACME challenge**:
```bash
kubectl get challenges -A
kubectl describe challenge -n namespace challenge-name
```

## Performance Tuning

### Resource Limits

Set appropriate resource limits:

```yaml
resources:
  requests:
    cpu: 100m
    memory: 128Mi
  limits:
    cpu: 500m
    memory: 512Mi
```

### Node Affinity

Control pod placement:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: node-role.kubernetes.io/worker
          operator: Exists
```

### Pod Disruption Budgets

Ensure availability during updates:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: my-app-pdb
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: my-app
```

## Maintenance

### Cluster Updates

K3s updates are handled by NixOS configuration updates. Update the K3s version in your NixOS configuration and rebuild.

### Application Updates

Applications are updated by modifying their manifests or Helm values and committing to git. Flux automatically applies changes.

### Backup and Recovery

See the [Disaster Recovery Guide](disaster-recovery.md) for backup procedures.

## Best Practices

### GitOps Workflow

1. Make changes in git
2. Create pull request for review
3. Merge to main branch
4. Flux automatically applies changes
5. Monitor deployment status

### Security

- Use network policies to restrict pod communication
- Implement RBAC for service accounts
- Regularly update container images
- Scan images for vulnerabilities
- Use admission controllers for policy enforcement

### Resource Management

- Set resource requests and limits
- Use horizontal pod autoscaling
- Monitor resource usage with Prometheus
- Implement pod disruption budgets
- Use node affinity for workload placement
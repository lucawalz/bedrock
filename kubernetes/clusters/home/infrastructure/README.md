# Infrastructure Layer

Core infrastructure components deployed in dependency order:

1. **Storage** (Longhorn) - Deployed first
2. **Networking** (Traefik, cert-manager, external-dns) - Needs storage
3. **Monitoring** (Prometheus/Grafana) - Needs networking

Each component should have:
- Namespace
- HelmRelease (for Helm charts)
- Values file (Helm values)
- Ingress (if applicable)


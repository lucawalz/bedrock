# Home Cluster Configuration

This directory contains the complete Kubernetes cluster configuration for the home cluster.

## Structure

- **sources/** - Helm repositories and Git sources
- **config/** - Cluster-wide configuration (domain, timezone, etc.)
- **infrastructure/** - Core infrastructure deployed in layers
  - storage/ - Longhorn
  - networking/ - Traefik, cert-manager, external-dns
  - monitoring/ - Prometheus/Grafana stack
- **apps/** - Applications grouped by function
  - databases/ - PostgreSQL, Redis, etc.
  - dashboards/ - Glance, Uptime Kuma
  - media/ - Plex, Jellyfin (future)
- **secrets/** - Encrypted Kubernetes secrets (SOPS)

## Deployment

Flux automatically deploys resources in dependency order. Infrastructure is deployed before applications.

## Cluster Domain

Set your cluster domain in `config/cluster-settings.yaml` (if using external-dns or Ingress).

## Accessing Services

- Traefik dashboard: `traefik.syslabs.dev`
- Grafana: `grafana.syslabs.dev`
- Glance: `glance.syslabs.dev` (when deployed)

All services use TLS certificates from Let's Encrypt via cert-manager.

## DNS Configuration

For the domain `syslabs.dev` to work, you need to:

1. **Point DNS records** to your public IP:
   - Create A records: `traefik.syslabs.dev`, `grafana.syslabs.dev`, etc.
   - Or use a wildcard: `*.syslabs.dev` → your public IP

2. **Port forwarding** (if behind NAT):
   - Forward ports 80 and 443 to your Traefik service

3. **Optional: Use external-dns**:
   - Configure external-dns with your DNS provider (Cloudflare, etc.)
   - It will automatically create DNS records for your ingresses


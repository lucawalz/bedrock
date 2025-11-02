# Applications

Applications deployed on the cluster, organized by function.

## Structure

- **databases/** - Database services (PostgreSQL, Redis, etc.)
- **dashboards/** - Dashboard and homepage apps (Glance, Uptime Kuma)
- **media/** - Media services (Plex, Jellyfin) - future

Each app directory typically contains:
- `namespace.yaml` - Kubernetes namespace
- `helmrelease.yaml` or `deployment.yaml` - Application definition
- `values.yaml` - Configuration values
- `ingress.yaml` - Ingress for external access (if needed)
- `pvc.yaml` - Persistent volume claims (if needed)

## Deployment

Apps are deployed after infrastructure is ready. Dependencies are handled automatically by Flux.


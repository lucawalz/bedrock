# Infrastructure Layer

Core infrastructure components deployed in dependency order:

1. **Storage** (Longhorn) - Deployed first
2. **Networking** (Traefik, cert-manager, external-dns) - Needs storage
3. **Monitoring** (Prometheus/Grafana) - Needs networking

## Standardized Component Structure

Each component follows a consistent pattern:
- **Namespace** - Component namespace definition
- **ConfigMap** - Helm values stored as ConfigMap
- **HelmRelease** - Uses `valuesFrom` to reference ConfigMap
- **Kustomization** - Orchestrates all resources
- **Ingress** - Optional, if component needs external access

## Benefits of ConfigMap Approach

- **Maintainability**: Values separated from HelmRelease definitions
- **Consistency**: All components follow the same pattern  
- **Flexibility**: Easy to modify values without touching HelmRelease
- **Version Control**: Clear diffs when values change
- **Reusability**: ConfigMaps can be shared between HelmReleases

See `TEMPLATE.md` for the standardized component structure.


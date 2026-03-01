# Infrastructure Layer

Core infrastructure components deployed in dependency order:

1. **Storage** (Longhorn) — Deployed first
2. **Networking** (Traefik, cert-manager, Cloudflare tunnel) — Needs storage
3. **Databases** (PostgreSQL) — Needs networking
4. **Monitoring** (Prometheus/Grafana) — Needs networking
5. **CI/CD** (Tekton) — Needs networking

## Standardized Component Structure

Each component follows a consistent pattern:
- **ConfigMap** — Helm values stored as ConfigMap
- **HelmRelease** — Uses `valuesFrom` to reference ConfigMap
- **Kustomization** — Orchestrates all resources
- **Ingress** — Optional, if component needs external access

> **Note:** Namespace definitions are centralized in `../namespaces/`, not inside infrastructure directories.

## Benefits of ConfigMap Approach

- **Maintainability**: Values separated from HelmRelease definitions
- **Consistency**: All components follow the same pattern
- **Flexibility**: Easy to modify values without touching HelmRelease
- **Version Control**: Clear diffs when values change

See `TEMPLATE.md` for the standardized component structure.


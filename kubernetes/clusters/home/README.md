# Home Cluster Configuration

This directory contains the complete Kubernetes cluster configuration for the home cluster.

## Structure

- **namespaces/** — Centralized namespace definitions (deployed first)
- **sources/** — Helm repositories (`helm/`) and OCI sources (`oci/`)
- **config/** — Flux Kustomizations defining deployment order
- **secrets/** — Encrypted Kubernetes secrets (SOPS)
- **infrastructure/** — Core infrastructure deployed in layers
  - `storage/` — Longhorn
  - `networking/` — Traefik, cert-manager, Cloudflare tunnel
  - `databases/` — PostgreSQL
  - `monitoring/` — Prometheus/Grafana stack
  - `cicd/` — Tekton
- **apps/** — Applications grouped by function
  - `dashboards/` — Glance
  - `it-tools/`, `n8n/` — Standalone apps
  - `sentio-systems/` — Multi-service application
- **flux-system/** — Flux bootstrap (auto-managed, do not edit)

## Deployment Order

Flux deploys resources via `config/` Kustomizations in this order:

```
Layer 0:  cluster-namespaces    (no deps)
          cluster-sources       (no deps)
Layer 1:  cluster-secrets       (depends: namespaces)
Layer 2:  cluster-infrastructure (depends: sources, secrets, namespaces)
Layer 3:  cluster-issuers       (depends: infrastructure, namespaces)
Layer 4:  cluster-apps          (depends: infrastructure, issuers, namespaces)
```

## Accessing Services

- Traefik dashboard: `traefik.syslabs.dev`
- Grafana: `grafana.syslabs.dev`
- Glance: `glance.syslabs.dev`

All services use TLS certificates from Let's Encrypt via cert-manager.


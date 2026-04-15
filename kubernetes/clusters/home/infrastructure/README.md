# infrastructure

Platform services deployed before apps. Each component follows the same pattern: a `ConfigMap` holds Helm values, a `HelmRelease` references it via `valuesFrom`. This keeps values diffs clean and separates config from chart version management.

## Components

| Layer | Component | Chart |
|---|---|---|
| Storage | Longhorn | `longhorn/longhorn` |
| Networking | Traefik | `traefik/traefik` |
| Networking | cert-manager | `jetstack/cert-manager` |
| Networking | Cloudflare Tunnel | plain deployment |
| Databases | PostgreSQL | `bitnami/postgresql` |
| Storage | Redis Operator | `ot-helm/redis-operator` |
| Monitoring | kube-prometheus-stack | `prometheus-community/kube-prometheus-stack` |
| CI/CD | Tekton | `cdf/tekton-pipeline` |

## Adding a component

```
infrastructure/<name>/
├── configmap.yaml     # Helm values
├── helmrelease.yaml   # Chart + valuesFrom reference
└── kustomization.yaml
```

Namespace goes in `../namespaces/`, not here.

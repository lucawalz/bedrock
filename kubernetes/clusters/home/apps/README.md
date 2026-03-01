# Applications

Applications deployed on the cluster, organized by function.

## Structure

- **dashboards/** — Dashboard and homepage apps (Glance)
- **it-tools/** — IT utilities
- **n8n/** — Workflow automation
- **sentio-systems/** — Multi-service application (backend, frontend, keycloak, mosquitto, etc.)

Each app directory typically contains:
- `helmrelease.yaml` or `deployment.yaml` — Application definition
- `ingress.yaml` — Ingress for external access (if needed)
- `kustomization.yaml` — Kustomize resource list

> **Note:** Namespace definitions are centralized in `../namespaces/`, not inside app directories.

## Deployment

Apps are deployed after infrastructure is ready. Dependencies are handled by Flux via the `cluster-apps` Kustomization which depends on `cluster-infrastructure`, `cluster-issuers`, and `cluster-namespaces`.


# NixOS + K3s Homelab

Declarative homelab running NixOS for OS management, K3s for Kubernetes, and Flux CD for GitOps.

---

## Stack

| Layer | Technology | Purpose |
|-------|-----------|---------|
| OS | NixOS (flakes) | Declarative, reproducible system config |
| Orchestration | K3s | Lightweight Kubernetes |
| GitOps | Flux CD | Continuous deployment from git |
| Storage | Longhorn | Distributed block storage |
| Ingress | Traefik | Load balancing, SSL termination |
| Certificates | cert-manager + Let's Encrypt | Automatic TLS |
| Monitoring | Prometheus + Grafana | Metrics and dashboards |
| DNS/Tunnel | Cloudflare Tunnel | Secure external access |
| Secrets | agenix (NixOS) + SOPS (K8s) | Encrypted at rest, decrypted at deploy |
| CI/CD | GitHub Actions + Tekton | Image builds, in-cluster pipelines |
| Database | PostgreSQL (Bitnami Helm) | Application data |

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│     master       │    │    worker-1      │    │    worker-N      │
│                  │    │                  │    │                  │
│ • K3s Server     │◄──►│ • K3s Agent      │◄──►│ • K3s Agent      │
│ • etcd           │    │ • Workloads      │    │ • Workloads      │
│ • Flux CD        │    │ • Longhorn       │    │ • Longhorn       │
│ • Traefik        │    │ • Monitoring     │    │ • Monitoring     │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

Nodes are fully declarative — rebuild any host from scratch with `nixos-anywhere --flake .#hostname root@IP`.

## Repository Structure

```
nixos-homelab/
├── flake.nix                  # Entry point — host definitions via lib/mkHost
├── lib/                       # Utility functions (mkHost helper)
├── hosts/                     # Per-host NixOS configurations
│   ├── common/                # Shared config (boot, locale, networking, nix, packages, users)
│   ├── master/                # Control plane (K3s server, services)
│   └── worker-1/              # Worker node (K3s agent, services)
├── modules/                   # Reusable NixOS modules
│   ├── k3s/                   # K3s server/agent/common
│   └── services/              # monitoring (node_exporter), storage (Longhorn prereqs)
├── secrets/                   # Encrypted NixOS secrets (agenix + age)
├── kubernetes/                # Kubernetes manifests (Flux GitOps)
│   └── clusters/home/
│       ├── namespaces/        # Centralized namespace definitions
│       ├── sources/           # Helm & OCI repositories
│       ├── config/            # Flux Kustomizations (deployment order)
│       ├── secrets/           # SOPS-encrypted K8s secrets
│       ├── infrastructure/    # storage, networking, databases, monitoring, cicd
│       ├── apps/              # sentio-systems, dashboards, it-tools, n8n
│       └── flux-system/       # Flux bootstrap (auto-managed)
└── docs/                      # Documentation
```

## Flux Deployment Order

```
Layer 0:  namespaces    (no deps)
          sources       (no deps)
Layer 1:  secrets       (depends: namespaces)
Layer 2:  infrastructure (depends: sources, secrets, namespaces)
Layer 3:  issuers       (depends: infrastructure, namespaces)
Layer 4:  apps          (depends: infrastructure, issuers, namespaces)
```

## Applications

| App | Description | Namespace |
|-----|-------------|-----------|
| **Sentio Systems** | Multi-service platform (backend, frontend, keycloak, AI services, MQTT) | `sentio-systems` |
| **Glance** | Dashboard | `dashboards` |
| **IT-Tools** | Developer utilities | `it-tools` |
| **n8n** | Workflow automation | `n8n` |

## Infrastructure

| Component | Namespace | Notes |
|-----------|-----------|-------|
| Longhorn | `longhorn-system` | Distributed storage, 2 replicas |
| Traefik | `traefik` | NodePort 30080/30443 |
| cert-manager | `cert-manager` | Let's Encrypt via DNS-01 |
| Cloudflare Tunnel | `cloudflare-tunnel` | Secure ingress without port forwarding |
| PostgreSQL | `postgres` | Bitnami Helm chart |
| Prometheus/Grafana | `monitoring` | kube-prometheus-stack |
| Tekton | `tekton-pipelines` | In-cluster CI/CD |

## Quick Reference

<details>
<summary><strong>NixOS</strong></summary>

```bash
make build HOST=master          # Test configuration build
make switch HOST=master         # Apply configuration
make switch HOST=worker-1       # Apply to worker

# Add a new worker: create hosts/worker-X/, add to flake.nix
# See hosts/README.md
```

</details>

<details>
<summary><strong>Kubernetes & Flux</strong></summary>

```bash
kubectl get nodes               # Cluster status
kubectl get pods -A             # All pods
flux get kustomizations -A      # Flux sync status
flux get helmreleases -A        # Helm releases
flux reconcile kustomization cluster-apps --with-source  # Force sync

make flux-check                 # Full Flux health check
make flux-bootstrap             # One-time Flux setup
```

</details>

<details>
<summary><strong>Secrets</strong></summary>

```bash
# NixOS (agenix)
agenix -e secrets/k3s-token.age

# Kubernetes (SOPS)
sops kubernetes/clusters/home/secrets/sentio-systems.sops.yaml
```

</details>

<details>
<summary><strong>Debugging</strong></summary>

```bash
journalctl -u k3s                                       # K3s logs
kubectl logs -n flux-system -l app=source-controller     # Flux source logs
kubectl logs -n flux-system -l app=kustomize-controller  # Flux kustomize logs
flux get image policy -n sentio-systems                  # Image automation status
```

</details>

## Documentation

| Doc | Covers |
|-----|--------|
| [Setup Process](docs/setup-process.md) | Full provisioning from bare metal to running cluster |
| [Kubernetes & Flux](docs/kubernetes-setup.md) | K3s config, Flux bootstrap, adding apps |
| [Secrets Management](docs/secrets-management.md) | agenix + SOPS, key rotation |
| [DNS Setup](docs/dns-setup.md) | Cloudflare tunnel, DNS records, certificates |
| [Disaster Recovery](docs/disaster-recovery.md) | Backups, restoration, emergency procedures |

## Key Design Decisions

- **Centralized namespaces** — All namespace definitions live in `kubernetes/clusters/home/namespaces/`, not scattered in app/infra dirs
- **ConfigMap-based Helm values** — Infrastructure HelmReleases use `valuesFrom` ConfigMaps for cleaner diffs
- **Parameterized NixOS modules** — K3s agent `serverAddr` uses `lib.mkDefault`, overridable per-host
- **Image automation** — Flux watches GHCR for stable semver tags from `main`, auto-commits updates
- **Firewall enabled** — SSH (22) open by default, K3s ports per role

## External Resources

| Resource | Link |
|----------|------|
| NixOS Manual | [nixos.org/manual](https://nixos.org/manual/nixos/) |
| K3s Docs | [docs.k3s.io](https://docs.k3s.io/) |
| Flux Docs | [fluxcd.io/docs](https://fluxcd.io/docs/) |
| Agenix | [github.com/ryantm/agenix](https://github.com/ryantm/agenix) |
| SOPS | [github.com/getsops/sops](https://github.com/getsops/sops) |

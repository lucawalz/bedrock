# nixos-homelab

> A self-hosted Kubernetes homelab running on bare-metal NixOS, managed entirely through GitOps.

---

## Architecture

Three physical nodes running NixOS with k3s, declared in a single Nix flake. All cluster state lives in this repository — Flux watches `main` and reconciles continuously. No manual `kubectl apply` in production.

```
┌─────────────────────────────────────────────────────┐
│                    GitHub (this repo)               │
│   flake.nix ──► NixOS configs    kubernetes/ ──► Flux│
└────────────┬──────────────────────────┬─────────────┘
             │ nixos-rebuild            │ GitOps
    ┌────────▼────────┐       ┌─────────▼────────────┐
    │   NixOS Layer   │       │    Kubernetes Layer   │
    │                 │       │                       │
    │  master         │       │  Flux · Helm · SOPS   │
    │  worker-1       │       │  Longhorn · Traefik   │
    │  worker-2       │       │  cert-manager         │
    └─────────────────┘       └───────────────────────┘
```

**External access** is via a Cloudflare Tunnel (no open inbound ports). TLS is terminated at Traefik using Let's Encrypt certificates issued through Cloudflare DNS-01 challenges.

---

## Nodes

| Node | Role | IP |
|---|---|---|
| master | control-plane + etcd | 192.168.2.191 |
| worker-1 | worker | 192.168.2.100 |
| worker-2 | worker | — |

All nodes are declared in `flake.nix`, provisioned with [disko](https://github.com/nix-community/disko), and share a common base config in `hosts/common/`.

---

## Repository Layout

```
├── flake.nix                    # Entry point — all three nodes declared here
├── hosts/
│   ├── common/                  # Shared config (boot, locale, users, networking)
│   └── master/                  # Master-specific (disko, hardware)
├── modules/
│   ├── k3s/                     # k3s server + agent modules
│   └── services/                # Monitoring and storage NixOS modules
├── secrets/                     # agenix-encrypted NixOS secrets
└── kubernetes/clusters/home/
    ├── flux-system/             # Flux bootstrap manifests
    ├── infrastructure/          # Platform services (below)
    └── apps/                    # Workloads (below)
```

---

## Infrastructure

### Networking

| Component | Why |
|---|---|
| **Traefik** | Ingress controller. Chosen over nginx for its native Kubernetes CRDs and automatic Let's Encrypt integration. |
| **cert-manager** | Automates TLS certificate issuance and renewal via Cloudflare DNS-01 — no HTTP challenge needed since ports aren't exposed. |
| **Cloudflare Tunnel** | Runs as two replicas; exposes services externally without opening firewall ports. Zero-trust by default. |

### Storage

| Component | Why |
|---|---|
| **Longhorn** | Distributed block storage across all three nodes. Chosen over NFS for its replicated volumes, snapshot support, and native CSI integration. Each volume is replicated 2×. |
| **PostgreSQL** (Bitnami) | Shared relational database for apps that need one (Keycloak, n8n). |
| **Redis** (redis-operator) | In-cluster cache and pub/sub for Sentio Systems. |

### Observability

| Component | Why |
|---|---|
| **kube-prometheus-stack** | The standard Kubernetes monitoring bundle: Prometheus, Alertmanager, and Grafana in one chart. |

### CI/CD

| Component | Why |
|---|---|
| **Tekton** | In-cluster pipeline runner for building and pushing container images. |

---

## Apps

### Sentio Systems

A self-hosted bird monitoring platform — the primary reason this cluster exists.

| Service | Purpose |
|---|---|
| **frontend** | React web app |
| **backend** | API server |
| **birder** | Captures video frames from cameras |
| **preprocessing** | Prepares frames for species detection |
| **speciesnet** | Runs the ML species identification model |
| **MediaMTX** | RTSP media server — ingests camera streams and makes them available in-cluster |
| **Mosquitto** | MQTT broker for sensor/camera event messaging |
| **Keycloak** | Identity provider and SSO for all Sentio services |

### Utilities

| Service | Purpose |
|---|---|
| **n8n** | Workflow automation for alerts, integrations, and data pipelines |
| **it-tools** | Browser-based developer toolbox |
| **Glance** | Homelab dashboard |

---

## Secrets Management

**NixOS secrets** (k3s tokens, SSH keys) are encrypted with [agenix](https://github.com/ryantm/agenix) using each node's SSH host key. Secrets are decrypted at boot.

**Kubernetes secrets** (API keys, credentials) are encrypted with [SOPS](https://github.com/getsops/sops) + age and committed as `*.sops.yaml` files. Flux decrypts them in-cluster.

---

## Updates

Dependencies are kept current via [Renovate](https://docs.renovatebot.com/), which opens automated PRs for:

- `flake.lock` — bumps nixpkgs (kernel, k3s, system packages)
- Helm chart versions in `HelmRelease` manifests
- GitHub Actions versions

Infrastructure charts are grouped and scheduled weekly. App charts are updated individually.

---

## CI

Every pull request runs:

| Check | What it catches |
|---|---|
| `nix flake check --no-build` | Nix syntax errors, invalid module options |
| `kubeconform` | Kubernetes manifests invalid against the API schema |
| `kustomize build` | Broken resource references in kustomizations |
| SOPS sanity check | Accidentally committed plaintext secrets |

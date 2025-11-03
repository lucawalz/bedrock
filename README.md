# NixOS + K3s Homelab

> A complete homelab setup using NixOS for operating system management and K3s for Kubernetes orchestration, with Flux CD for GitOps.

---

## Overview

This repository contains a **production-ready homelab configuration** with:

| Component | Purpose | Technology |
|-----------|---------|------------|
| **Operating System** | Declarative system configuration | NixOS |
| **Container Orchestration** | Lightweight Kubernetes distribution | K3s |
| **GitOps** | Continuous deployment | Flux CD |
| **Storage** | Distributed block storage | Longhorn |
| **Ingress** | Load balancing & SSL termination | Traefik |
| **Certificates** | TLS certificate management | cert-manager |
| **Monitoring** | Metrics & observability | Prometheus/Grafana |

## Architecture

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│     master      │    │    worker-1     │    │    worker-N     │
│                 │    │                 │    │                 │
│ • K3s Server    │◄──►│ • K3s Agent     │◄──►│ • K3s Agent     │
│ • etcd          │    │ • Workloads     │    │ • Workloads     │
│ • Flux CD       │    │ • Longhorn      │    │ • Longhorn      │
│ • Traefik      │    │ • Monitoring    │    │ • Monitoring    │
└─────────────────┘    └─────────────────┘    └─────────────────┘
```

### Node Roles

| Node Type | Role | Components |
|-----------|------|------------|
| **master** | Control Plane | K3s server, etcd, Flux CD, Traefik ingress |
| **worker-1** | Compute Node | K3s agent, application workloads, storage |
| **worker-N** | Compute Node | Unlimited scalability - add as needed |

> **Scalable Design**: Start with 2 nodes, expand to as many workers as needed. Each node is declaratively configured and automatically joins the cluster.

## Getting Started

<table>
<tr>
<th>User Type</th>
<th>Recommended Path</th>
<th>Description</th>
</tr>
<tr>
<td><strong>New Users</strong></td>
<td><a href="docs/complete-setup-guide.md"><strong>Complete Setup Guide</strong></a></td>
<td>Step-by-step instructions from zero to running homelab</td>
</tr>
<tr>
<td><strong>NixOS Veterans</strong></td>
<td><a href="QUICK_START.md"><strong>Quick Start Guide</strong></a></td>
<td>Fast deployment for experienced users</td>
</tr>
<tr>
<td><strong>Need Help?</strong></td>
<td><a href="docs/README.md"><strong>Documentation Index</strong></a></td>
<td>Find guides for specific topics and troubleshooting</td>
</tr>
</table>

## Repository Structure

```
nixos-homelab/
├── hosts/              # Per-host NixOS configurations
├── roles/              # Role-based configs (k3s-server, k3s-agent)
├── secrets/            # Encrypted NixOS secrets (agenix)
├── kubernetes/         # Kubernetes manifests (Flux GitOps)
├── docs/               # Documentation
└── modules/            # Custom NixOS modules
```

## Quick Commands

<details>
<summary><strong>Click to expand command reference</strong></summary>

### NixOS Operations
```bash
just build master          # Test configuration build
just switch master         # Apply configuration to master
just switch worker-1       # Apply configuration to worker
```

### Kubernetes Operations
```bash
just flux-check           # Check Flux GitOps status
just flux-bootstrap       # Bootstrap Flux (one-time)
kubectl get nodes         # Check cluster node status
kubectl get pods -A       # Check all pods across namespaces
```

### Secrets Management
```bash
agenix -e secrets/k3s-token.age              # Edit NixOS secrets
sops kubernetes/.../secret.sops.yaml         # Edit Kubernetes secrets
```

### Monitoring & Debugging
```bash
kubectl logs -n flux-system -l app=source-controller    # Flux logs
kubectl get helmreleases -A                             # Helm releases
journalctl -u k3s                                       # K3s service logs
```

</details>

## What Makes This Different

<table>
<tr>
<th>Traditional Homelab</th>
<th>This NixOS Setup</th>
</tr>
<tr>
<td>

```diff
- Manual OS installation
- Package dependency conflicts
- Configuration drift over time
- Hard to reproduce setups
- Manual backup procedures
- Imperative updates (apt, yum)
- "Works on my machine" issues
- Manual secret management
```

</td>
<td>

```diff
+ Automated OS deployment
+ Isolated, reproducible packages
+ Declarative, drift-free config
+ Identical setups every time
+ Automated GitOps backups
+ Atomic, rollback-able updates
+ Guaranteed reproducibility
+ Encrypted secret management
```

</td>
</tr>
</table>

### Key Benefits

| Feature | Benefit | Implementation |
|---------|---------|----------------|
| **Infrastructure as Code** | Everything is version controlled | NixOS flakes + Kubernetes manifests |
| **GitOps Workflow** | Changes via git commits | Flux CD automatic synchronization |
| **Secret Management** | Secure, encrypted secrets | agenix (NixOS) + SOPS (Kubernetes) |
| **Zero Downtime** | Rolling updates | Kubernetes deployment strategies |
| **Disaster Recovery** | Quick restoration | Declarative configuration + backups |

## Perfect For

<table>
<tr>
<td><strong>Homelab Enthusiasts</strong></td>
<td>Modern infrastructure with enterprise-grade practices</td>
</tr>
<tr>
<td><strong>Kubernetes Learners</strong></td>
<td>Realistic environment for hands-on experience</td>
</tr>
<tr>
<td><strong>DevOps Engineers</strong></td>
<td>Practice GitOps workflows and infrastructure automation</td>
</tr>
<tr>
<td><strong>Infrastructure Nerds</strong></td>
<td>Declarative, reproducible systems that just work</td>
</tr>
</table>

---

## Resources & Documentation

| Resource | Description | Link |
|----------|-------------|------|
| **NixOS Manual** | Official NixOS documentation | [nixos.org/manual](https://nixos.org/manual/nixos/) |
| **K3s Documentation** | Lightweight Kubernetes guide | [docs.k3s.io](https://docs.k3s.io/) |
| **Flux Documentation** | GitOps toolkit documentation | [fluxcd.io/docs](https://fluxcd.io/docs/) |
| **Agenix** | NixOS secrets management | [github.com/ryantm/agenix](https://github.com/ryantm/agenix) |
| **SOPS** | Kubernetes secrets encryption | [github.com/getsops/sops](https://github.com/getsops/sops) |

---

## License

**MIT License** - Feel free to fork, modify, and adapt for your own needs!

> **Contributing**: This is a personal homelab repository, but issues and improvements are welcome. Share your own configurations and learnings with the community.


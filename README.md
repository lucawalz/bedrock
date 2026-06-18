# bedrock

[![nix flake check](https://github.com/lucawalz/bedrock/actions/workflows/nix-check.yaml/badge.svg)](https://github.com/lucawalz/bedrock/actions/workflows/nix-check.yaml)
[![kubernetes manifests](https://github.com/lucawalz/bedrock/actions/workflows/k8s-validate.yaml/badge.svg)](https://github.com/lucawalz/bedrock/actions/workflows/k8s-validate.yaml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![NixOS flakes](https://img.shields.io/badge/NixOS-flakes-5277C3?logo=nixos&logoColor=white)
![GitOps: Flux v2](https://img.shields.io/badge/GitOps-Flux%20v2-316CE6)

A bare-metal Kubernetes homelab that lives entirely in Git.

## Description

bedrock is the single source of truth for a small home cluster. Three mini PCs run [NixOS](https://nixos.org/) and a [K3s](https://k3s.io/) cluster, and a Raspberry Pi running NixOS acts as the router, gateway, and DNS for the network. Everything from each machine's disk layout to the workloads running on top is declared in this repository. Host configuration is applied with `nixos-rebuild`; cluster state is reconciled by [Flux](https://fluxcd.io/) from `kubernetes/clusters/home`, so a change to the `main` branch becomes a change to the cluster without anyone running commands against it by hand.

The cluster runs a self-hosted LLM stack, workflow automation, monitoring, and a few supporting services. A handful are public through a Cloudflare Tunnel; the rest are reachable only over Tailscale or the LAN. When the local nodes run short on capacity, the companion [horizon](https://github.com/lucawalz/horizon) controller provisions a temporary node on Hetzner Cloud through Cluster API, and it joins the cluster over the tailnet.

### Features

- Fully declarative hosts with NixOS flakes, including disk partitioning ([disko](https://github.com/nix-community/disko)) and per-host secrets ([agenix](https://github.com/ryantm/agenix)).
- GitOps reconciliation with Flux v2: the repository is the only way state reaches the cluster.
- Effectively no open inbound ports. Public access goes through an outbound [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/); admin and burst nodes reach the cluster over [Tailscale](https://tailscale.com/), where the Pi advertises the cluster subnet to the tailnet and NAT traversal needs no forwarded port.
- Replicated storage with [Longhorn](https://longhorn.io/) and off-site backups to Hetzner object storage with [Velero](https://velero.io/).
- On-demand cloud burst nodes booted from a pre-baked NixOS snapshot and joined to the cluster automatically.
- Cloud peer clusters reconciled from Git: a cluster labelled `bedrock.io/gitops-peer=true` self-bootstraps Flux through a Cluster API ClusterResourceSet, with AWS peers on managed EKS and Hetzner peers on self-hosted k3s.
- Secrets committed encrypted with [SOPS](https://github.com/getsops/sops) and age, decrypted only inside the cluster.

### Background

The point of the project is to keep a real cluster reproducible and reviewable. Rebuilding a node, recovering from a failure, or adding a service should be a matter of reading the repository and applying it, not remembering what was done by hand. The companion [horizon](https://github.com/lucawalz/horizon) controller drives the Cluster API manifests here to add and remove burst nodes as load changes.

## Architecture

The network is zoned. The cluster and servers sit on VLAN 20 (`10.20.0.0/24`); a separate DMZ on VLAN 30 (`10.30.0.0/24`) holds untrusted and future hosts, and the router firewall denies DMZ traffic to the cluster and the home network by default. Public traffic never reaches the LAN directly: Cloudflare terminates TLS at its edge and forwards only `chat`, `llm`, `n8n`, and `lucawalz.dev` through the tunnel to Traefik, which routes by hostname. The internal services stay off the public internet and are reached over Tailscale or the LAN through split-horizon DNS, where AdGuard on the Pi rewrites the internal service hostnames to the Traefik VIP while the public hosts continue to resolve through Cloudflare. cert-manager issues a wildcard `*.syslabs.dev` certificate over Let's Encrypt DNS-01, and Traefik serves it as the default certificate.

Cluster state flows the other way: a push to `main` is pulled by Flux, which applies the manifests in dependency order. A burst node is provisioned by the companion horizon controller through Cluster API from a pre-baked snapshot, enrolls into the tailnet headlessly with a reusable, ephemeral auth key tagged `tag:burst`, and joins the cluster as another K3s agent over the tailnet.

bedrock also declares cloud peer clusters, not only the home cluster and its burst nodes. A cluster authored under `kubernetes/clusters/home/infrastructure/cluster-api/` and labelled `bedrock.io/gitops-peer=true` is picked up by a Cluster API ClusterResourceSet, which installs Flux on it and points it at the shared cloud-safe `kubernetes/peers/base` overlay, so the peer reconciles its own GitOps from this repository without depending on the home cluster. The first peer is an AWS cluster, `aws-1`, on the managed EKS control plane through the Cluster API AWS provider, so AWS owns etcd, certificates, and control-plane upgrades; Hetzner clusters self-host k3s because Hetzner offers no managed control plane. The reasoning is in [ADR 0035](docs/adr/0035-standalone-gitops-managed-cloud-cluster.md) and [0036](docs/adr/0036-aws-via-managed-eks-control-plane.md).

![Network topology: Internet through the ISP and Pi routers to the VLAN 20 cluster and VLAN 30 DMZ, with Tailscale, Cloudflare Tunnel, and Flux GitOps planes, and horizon provisioning Hetzner Cloud capacity as a burst pool and a separate cluster](docs/network-topology.svg)

## Hardware

Three Lenovo ThinkCentre m920q nodes on VLAN 20, with a Raspberry Pi as the router, gateway, and DNS:

| Node | Role | Address |
|------|------|---------|
| master | K3s server and control plane | 10.20.0.10 |
| worker-1 | K3s agent | 10.20.0.11 |
| worker-2 | K3s agent | 10.20.0.12 |
| router | Pi gateway, firewall, DNS, Tailscale subnet router | 10.20.0.1 |

Services are exposed on a MetalLB VIP at `10.20.0.50`. The Pi joins the tailnet as a subnet router and advertises `10.20.0.0/24`, so admins with `--accept-routes` reach the cluster on its LAN addresses from anywhere, and remote burst nodes join across the internet. The home K3s nodes stay LAN-only.

NixOS does not manage device firmware, so firmware patching is manual: `rpi-eeprom` on the Pi and the m920q BIOS on the nodes.

## Requirements

- [Nix](https://nixos.org/download.html) with flakes enabled, for the host configurations and the dev shell.
- A GitHub account that owns this repository, for the Flux bootstrap.
- For burst nodes: a Hetzner Cloud project and a Tailscale tailnet with the subnet router running on the Pi.
- For an AWS EKS peer: an AWS account with the Cluster API AWS IAM roles bootstrapped through `clusterawsadm`, and a scoped credential committed as a SOPS secret.

The dev shell pins the rest of the toolchain (kubectl, helm, flux, sops, age, terraform, nixos-anywhere):

```
nix develop
```

## Installation

A fresh cluster is brought up in two stages: the hosts, then Flux.

1. Install NixOS on each machine and apply its configuration. For an existing host, build the configuration and push it over SSH:

   ```
   nixos-rebuild switch --flake .#master --target-host root@<master-ip>
   ```

2. Fork this repository, then bootstrap Flux once against the fork so the cluster reconciles from a repo under the operator's own control. From then on Flux manages itself, so upgrading it or changing the source is a commit rather than a re-bootstrap:

   ```
   flux bootstrap github \
     --owner=<github-user> \
     --repository=<fork> \
     --path=kubernetes/clusters/home \
     --personal
   ```

Flux installs its controllers, reads `kubernetes/clusters/home`, and reconciles the whole cluster from Git.

## Usage

Confirm the nodes are up:

```
$ kubectl get nodes
NAME       STATUS   ROLES                  AGE    VERSION
master     Ready    control-plane,etcd     219d   v1.35.2+k3s1
worker-1   Ready    <none>                 219d   v1.35.2+k3s1
worker-2   Ready    <none>                 219d   v1.35.2+k3s1
```

Change anything under `kubernetes/` by committing to `main`. Flux applies it within a minute, with no manual `kubectl apply`. Check what reconciled:

```
$ flux get kustomizations
NAME                     READY   MESSAGE
cluster-sources          True    Applied revision: main@sha1:...
cluster-infrastructure   True    Applied revision: main@sha1:...
cluster-apps             True    Applied revision: main@sha1:...
```

Update a physical node after editing its NixOS configuration:

```
nixos-rebuild switch --flake .#worker-1 --target-host root@<worker-1-ip>
```

Burst nodes are not added by hand. The companion horizon controller provisions them through the Cluster API manifests under `kubernetes/clusters/home/infrastructure/cluster-api/`, enrolling the node into the tailnet with a tagged auth key and injecting the join token it needs, and removes them again when load drops.

The reconciliation order and the steps for adding a service are in [`kubernetes/README.md`](kubernetes/README.md).

## Repository layout

```
flake.nix              entry point; defines every host and the dev shells
lib/                   mkHost and mkWorker builders that keep host definitions small
hosts/
  common/              shared base: boot, locale, networking, users, packages, nix
  master/              control-plane node, with its disk layout and hardware scan
modules/
  k3s/                 server, agent, and Hetzner burst-agent roles
  router/              firewall, NAT, and the Tailscale subnet router
  services/            Longhorn storage prerequisites
secrets/               agenix-encrypted host secrets (the K3s join token)
kubernetes/
  clusters/home/       the live cluster Flux reconciles, including the cluster-api manifests the horizon controller drives
  peers/base/          shared cloud-safe overlay that GitOps peer clusters reconcile
```

Workers have no directory of their own. `flake.nix` builds them from `lib.mkWorker`, so adding worker-3 takes one line in the flake and one public key in `secrets/secrets.nix`.

The Cluster API manifests under `kubernetes/clusters/home/infrastructure/cluster-api/` are driven by the [horizon](https://github.com/lucawalz/horizon) controller rather than applied by hand.

## Services

Each service is reached at a subdomain of the cluster domain. The public ones go through the tunnel; the rest are internal-only, reachable over Tailscale or the LAN through split-horizon DNS:

| Service | Purpose | Access |
|---------|---------|--------|
| Open WebUI | chat front-end for the local models | public (`chat`) |
| LiteLLM | OpenAI-compatible gateway in front of Ollama | public (`llm`) |
| n8n | workflow automation | public (`n8n`) |
| Blog | static Hugo site | public (`lucawalz.dev`) |
| Homepage | cluster dashboard and links | internal (`home`) |
| Grafana | dashboards for the Prometheus stack | internal |
| Rancher | cluster management UI | internal |
| pgAdmin | Postgres administration | internal |
| Longhorn | storage management UI | internal |
| Traefik | router dashboard | internal |
| ntfy | alert sink for Alertmanager and Flux | internal (`ntfy`) |

Ollama serves the models (`qwen2.5-coder:7b` and `llama3.1:8b`) on worker-1 and stays internal. A single Postgres instance backs n8n, LiteLLM, and pgAdmin.

## Security

Secrets use two mechanisms, both committed encrypted, never in plaintext:

- Host secrets use agenix, encrypted to each node's SSH host key. Only the K3s join token lives here. See [`secrets/README.md`](secrets/README.md).
- Kubernetes secrets use SOPS with age, decrypted by Flux in-cluster at reconcile time. See [`kubernetes/clusters/home/secrets/README.md`](kubernetes/clusters/home/secrets/README.md).

Several layers of defense-in-depth sit on top. The app namespaces run default-deny NetworkPolicies, so a pod reaches only what it is explicitly allowed to. Workloads run with a non-root, dropped-capability securityContext. [Falco](https://falco.org/) watches for anomalous runtime behaviour on every node, and K3s encrypts Secrets at rest.

## Continuous integration

Every pull request runs three checks:

- `nix flake check` for Nix syntax and module options.
- `kubeconform` and `kustomize build` for the Kubernetes manifests.
- a SOPS check that no plaintext secret was committed.

[Renovate](https://docs.renovatebot.com/) keeps `flake.lock`, Helm chart versions, and GitHub Actions current through automated pull requests.

## Roadmap

- Automated burst scaling driven by the [horizon](https://github.com/lucawalz/horizon) controller, so nodes are added and removed by cluster load rather than by hand.
- Broader alerting on top of the existing Prometheus and Grafana stack.

This is a personal setup that changes as needs change, so the roadmap is a direction rather than a commitment.

## Contributing

This is a personal homelab, not a product, but issues and forks are welcome. Anyone reusing the layout is encouraged to adapt it to their own hardware and domain.

To work on it locally, clone the repository and enter the dev shell with `nix develop`, then run `nix flake check` before opening a pull request. The same Kubernetes validation that runs in CI can be reproduced with `kustomize build` and `kubeconform` against the manifests under `kubernetes/`.

## Support

Open an issue on the [GitHub repository](https://github.com/lucawalz/bedrock/issues) for questions or problems.

## Authors and acknowledgment

Built and maintained by Luca Walz. It stands on a lot of open-source work, in particular NixOS, K3s, Flux, nixos-anywhere, disko, agenix, SOPS, Longhorn, Traefik, and the chart maintainers behind the services it runs.

## License

Released under the MIT License. See [`LICENSE`](LICENSE).

## Project status

Actively maintained and running in production at home.

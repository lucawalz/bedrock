# bedrock

[![nix flake check](https://github.com/lucawalz/bedrock/actions/workflows/nix-check.yaml/badge.svg)](https://github.com/lucawalz/bedrock/actions/workflows/nix-check.yaml)
[![kubernetes manifests](https://github.com/lucawalz/bedrock/actions/workflows/k8s-validate.yaml/badge.svg)](https://github.com/lucawalz/bedrock/actions/workflows/k8s-validate.yaml)
[![license: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![NixOS flakes](https://img.shields.io/badge/NixOS-flakes-5277C3?logo=nixos&logoColor=white)
![GitOps: Flux v2](https://img.shields.io/badge/GitOps-Flux%20v2-316CE6)

A bare-metal Kubernetes homelab that lives entirely in Git.

## Description

bedrock is the single source of truth for a small home cluster. Three mini PCs run [NixOS](https://nixos.org/) and a [K3s](https://k3s.io/) cluster, and a Raspberry Pi running NixOS acts as the router, gateway, and DNS for the network. Everything from each machine's disk layout to the workloads running on top is declared in this repository. Host configuration is applied with `nixos-rebuild`; cluster state is reconciled by [Flux](https://fluxcd.io/) from `kubernetes/clusters/home`, so a change to the `main` branch becomes a change to the cluster without anyone running commands against it by hand.

The cluster runs a self-hosted LLM stack, workflow automation, monitoring, and a few supporting services. A handful are public through a Cloudflare Tunnel; the rest are reachable only over Tailscale or the LAN. Capacity is the three local nodes and nothing else: the cloud account that once supplied burst nodes was closed, and the machinery that used it is kept dormant rather than removed ([ADR 0081](docs/adr/0081-retire-the-hetzner-account.md)).

### Features

- Fully declarative hosts with NixOS flakes, including disk partitioning ([disko](https://github.com/nix-community/disko)) and per-host secrets ([agenix](https://github.com/ryantm/agenix)).
- GitOps reconciliation with Flux v2, carried declaratively by the Flux Operator: the repository is the only way state reaches the cluster.
- Effectively no open inbound ports. Public access goes through an outbound [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/); admins reach the cluster over [Tailscale](https://tailscale.com/), where every node joins the tailnet directly and NAT traversal needs no forwarded port.
- Replicated storage with [Longhorn](https://longhorn.io/), which keeps three replicas of every volume across the three nodes. There are no off-site backups; see [Disaster recovery](#disaster-recovery).
- Secrets committed encrypted with [SOPS](https://github.com/getsops/sops) and age, decrypted only inside the cluster.

### Background

The point of the project is to keep a real cluster reproducible and reviewable. Rebuilding a node, recovering from a failure, or adding a service should be a matter of reading the repository and applying it, not remembering what was done by hand. Cloud capacity followed the same principle for a while: an elastic autoscaler scaled a pool from zero until [ADR 0062](docs/adr/0062-retire-elastic-cluster-autoscaler.md) retired it, and the companion [horizon](https://github.com/lucawalz/horizon) tool then added and removed reserved nodes on demand. That path closed with the cloud account ([ADR 0081](docs/adr/0081-retire-the-hetzner-account.md)). The horizon operator, the node image and the measurement harness stay in the repository, configured against no provider, so the estate reads as three nodes and nothing that bursts.

## Architecture

The network is zoned. The cluster and servers sit on VLAN 20 (`10.20.0.0/24`); a separate DMZ on VLAN 30 (`10.30.0.0/24`) holds untrusted and future hosts, and the router firewall denies DMZ traffic to the cluster and the home network by default. Public traffic never reaches the LAN directly: Cloudflare terminates TLS at its edge and forwards only `chat`, `rancher`, and `lucawalz.dev` through the tunnel to Traefik, which routes by hostname. The internal services stay off the public internet and are reached over Tailscale or the LAN through split-horizon DNS, where AdGuard on the Pi rewrites the internal service hostnames to the Traefik VIP while the public hosts continue to resolve through Cloudflare. cert-manager issues a wildcard `*.syslabs.dev` certificate over Let's Encrypt DNS-01, and Traefik serves it as the default certificate.

Cluster state flows the other way: a push to `main` is pulled by Flux, which applies the manifests in dependency order. There is no path that adds capacity beyond the three local nodes. The horizon operator still runs and still owns lease and orphan-node collection ([ADR 0071](docs/adr/0071-deploy-horizon-operator-from-published-chart.md)), but it has no provider to lease from, so it provisions nothing until one is configured again.

## Hardware

Three Lenovo ThinkCentre m920q nodes on VLAN 20, with a Raspberry Pi as the router, gateway, and DNS:

| Node | Role | Address |
|------|------|---------|
| control-plane-1 | K3s server and control plane | 10.20.0.10 |
| worker-1 | K3s agent | 10.20.0.11 |
| worker-2 | K3s agent | 10.20.0.12 |
| router | Pi gateway, firewall, DNS, Tailscale subnet router | 10.20.0.1 |

A TP-Link TL-SG108PE carries the VLAN tags at layer 2 and powers the Pi over PoE on port 2, so the router runs from a single cable. It is managed at a static address on the home LAN, and its port map is recorded in [ADR 0050](docs/adr/0050-poe-switch-powers-the-router.md).

Services are exposed on a MetalLB VIP at `10.20.0.50`. The Pi joins the tailnet as a subnet router and advertises `10.20.0.0/24`, so admins with `--accept-routes` reach the cluster on its LAN addresses from anywhere, and the three nodes join the tailnet directly as well ([ADR 0074](docs/adr/0074-home-nodes-on-the-tailnet.md)).

NixOS does not manage device firmware, so firmware patching is manual: `rpi-eeprom` on the Pi and the m920q BIOS on the nodes.

## Requirements

- [Nix](https://nixos.org/download.html) with flakes enabled, for the host configurations and the dev shell.
- A GitHub account that owns this repository, for the Flux bootstrap.
- A Tailscale tailnet, with the subnet router running on the Pi.

The dev shell pins the rest of the toolchain (kubectl, helm, flux, sops, age, nixos-anywhere):

```
nix develop
```

## Installation

A fresh cluster is brought up in two stages: the hosts, then Flux.

1. Install NixOS on each machine and apply its configuration. For an existing host, build the configuration and push it over SSH:

   ```
   nixos-rebuild switch --flake .#control-plane-1 --target-host root@<control-plane-1-ip> --build-host root@<control-plane-1-ip>
   ```

   `--build-host` is not optional here. See [Rebuilding a host](#rebuilding-a-host).

2. Fork this repository, then seed Flux once against the fork so the cluster reconciles from a repo under the operator's own control:

   ```
   flux bootstrap github \
     --owner=<github-user> \
     --repository=<fork> \
     --path=kubernetes/clusters/home \
     --personal
   ```

   This installs the controllers and the `flux-system` Git source, which then reconcile `kubernetes/clusters/home`. The manifests there include the [Flux Operator](https://fluxcd.control-plane.io/operator/), which adopts the install in place and carries it declaratively as a `FluxInstance` from then on, so changing the controllers, the distribution, or the source is a commit rather than a re-bootstrap. The reasoning is in [ADR 0037](docs/adr/0037-flux-operator-controlplane-install.md).

Flux reads `kubernetes/clusters/home` and reconciles the whole cluster from Git.

## Usage

Confirm the nodes are up:

```
$ kubectl get nodes
NAME              STATUS   ROLES                  AGE    VERSION
control-plane-1   Ready    control-plane,etcd     219d   v1.35.2+k3s1
worker-1          Ready    <none>                 219d   v1.35.2+k3s1
worker-2          Ready    <none>                 219d   v1.35.2+k3s1
```

Change anything under `kubernetes/` by committing to `main`. Flux applies it within a minute, with no manual `kubectl apply`. Check what reconciled:

```
$ flux get kustomizations
NAME                     READY   MESSAGE
cluster-sources          True    Applied revision: main@sha1:...
cluster-storage          True    Applied revision: main@sha1:...
cluster-edge-onprem      True    Applied revision: main@sha1:...
cluster-apps             True    Applied revision: main@sha1:...
```

Update a physical node after editing its NixOS configuration:

```
nixos-rebuild switch --flake .#worker-1 --target-host root@<worker-1-ip> --build-host root@10.20.0.10
```

### Rebuilding a host

`--target-host` on its own builds the closure on the machine the command runs from. From an arm64 macOS workstation that fails for every host in this repository, because it can produce neither the x86_64-linux closure the cluster nodes need nor the aarch64-linux one the router needs. `--build-host` moves the build to a machine that can.

control-plane-1 is the build host for day-to-day work, and `boot.binfmt.emulatedSystems` on control-plane-1 covers the router's aarch64 closure as well as the nodes' own. During a cold rebuild, when control-plane-1 does not exist yet, point `--build-host` at the target itself.

Do not prefix the command with `sudo`. With both hosts set, nothing is built or activated locally, so local root is never needed, and sudo relocates `$HOME` to `/var/root`, which holds no SSH key for the cluster. The same cause makes a `builders` line in a user-level `nix.conf` inert.

Flux applies the Kustomizations in dependency order, and a layer whose dependencies are not ready waits rather than failing: `cluster-sources` and `cluster-namespaces` first, then `cluster-bootstrap-secrets` and `cluster-secrets`, then the platform Kustomizations under `infrastructure/`, then `cluster-issuers` on top of cert-manager, and finally `cluster-apps`, which fans out into one Kustomization per app. The platform layer is roughly twenty Kustomizations, each carrying its own `dependsOn`; `cluster-cert-manager`, `cluster-storage`, `cluster-edge-onprem`, and `cluster-observability` are examples rather than the whole set. All of them are defined in `kubernetes/clusters/home/config/`, which is the list to read.

To add a service: create its namespace under `namespaces/` and list it in that folder's kustomization, and add a HelmRepository under `sources/helm/` if the chart needs a new one. Then create `apps/<name>/` by copying an existing app: a `ks.yaml` Flux Kustomization naming the path, the app's dependencies, and a `postBuild.substituteFrom` on the `cluster-settings` ConfigMap, plus an `app/` directory holding the workload, a Traefik IngressRoute whose host reads `${cluster_domain}`, and a `kustomization.yaml` that pulls in the shared `components/` for network policies and forward-auth. An app that also pulls in the `traefik-ingress` network-policy component sets `APP` and `APP_PORT` in its `ks.yaml`, because that shared policy templates the workload label and the container port from them; an app that only takes the base policies needs neither. Add the directory to `apps/kustomization.yaml`. Any secret the app needs goes into the private `bedrock-secrets` repository rather than this one ([ADR 0060](docs/adr/0060-private-secrets-repo-per-cluster-keys.md)). Commit to `main`, and Flux applies it on its next pass.

## Repository layout

```
flake.nix              entry point; defines every host and the dev shells
lib/                   the inventory and the mkHost/clusterNodes builders that keep host definitions small
hosts/
  common/              shared base: boot, locale, networking, users, packages, nix
  control-plane-1/     control-plane node, with its disk layout and hardware scan
  router/              the Pi, composed from the router modules
  router-installer.nix the installer image that writes the Pi's first system
modules/
  k3s/                 server and agent roles, plus the dormant burst-node role
  router/              firewall, NAT, DHCP, DNS, wireless, and the bar-display kiosk
  tailscale/           the subnet router that advertises the LAN to the tailnet
  services/            Longhorn storage prerequisites
secrets/               agenix-encrypted host secrets: the K3s join token, the router's Tailscale and AdGuard credentials, the wifi passphrase, and the kiosk dashboard URL
infra/packer/          the dormant Packer template that bakes a cloud node snapshot
scripts/               the checks CI runs (ADR index, inventory generation, substitution rendering) plus the horizon burst-node measurement harness, the fixed synthetic quantum, and the requirements-based sizing campaign driver that prices it
tests/                 Kyverno policy tests and promtool alert-rule tests
docs/                  the ADR log, the cluster inventory, and the disaster recovery, admission break-glass and alert selector audit runbooks
kubernetes/
  apps/                workloads Flux reconciles, one directory per app
  components/          shared kustomize components (network policies, forward-auth)
  infrastructure/      the platform, split into controllers/ (operator installs) and configs/ (their custom resources)
  clusters/home/       the cluster entrypoint: the Flux Kustomization definitions, namespaces, sources, and the bootstrap secret that reaches the private secrets repository
```

`flake.nix` generates every cluster node from `lib.clusterNodes`, dispatching on the `role` each node carries in the inventory; `mkHost` is only used for the router now. Workers have no directory of their own, and adding one is an inventory entry rather than a flake edit, but that entry is not the whole cost: it still needs an agenix entry in `secrets/secrets.nix`, its own `tailscale-authkey-<name>.age`, and its host key added to `k3s-token.age`.

There is no capacity beyond the three local nodes. The Cluster API substrate a multi-region fleet once used was removed with the return to a single cluster ([ADR 0063](docs/adr/0063-return-to-single-region.md)), and the on-demand path that replaced it closed with the cloud account ([ADR 0081](docs/adr/0081-retire-the-hetzner-account.md)). Flux reconciles the platform under `kubernetes/infrastructure/`, and nothing here is applied by hand.

## Services

Each service is reached at a subdomain of the cluster domain. The public ones go through the tunnel; the rest are internal-only, reachable over Tailscale or the LAN through split-horizon DNS:

| Service | Purpose | Access |
|---------|---------|--------|
| Open WebUI | chat front-end for the local models | public (`chat`) |
| Blog | static Hugo site | public (`lucawalz.dev`) |
| Rancher | cluster management UI | public (`rancher`) |
| Homepage | cluster dashboard and links | internal (`home`) |
| Grafana | dashboards for the Prometheus stack | internal (`grafana`) |
| Prometheus | metrics store and query browser | internal (`prometheus`) |
| Alertmanager | alert routing, grouping, and silences | internal (`alertmanager`) |
| Authentik | single sign-on and identity provider | internal (`auth`) |
| LiteLLM | OpenAI-compatible gateway in front of Ollama | internal (`litellm`) |
| Miniflux | feed reader | internal (`rss`) |
| Kiwix | offline library of ZIM archives | internal (`kiwix`) |
| pgAdmin | Postgres administration | internal (`pgadmin`) |
| Longhorn | storage management UI | internal (`longhorn`) |
| MinIO | in-cluster S3 object storage and console | internal (`minio`, `s3`) |
| Zot | in-cluster OCI registry | internal (`registry`) |
| RackPeek | physical rack and node overview | internal (`rackpeek`) |
| Traefik | router dashboard | internal (`traefik`) |
| Flux | GitOps reconciliation dashboard | internal (`flux`) |
| horizon | lease and machine catalogue view, with no provider configured | internal (`horizon`) |
| ntfy | alert sink for Alertmanager and Flux | internal (`ntfy`) |
| Paperless | document archive with AI and GPT companions | internal (`paperless`) |
| Home Assistant | smart-home hub, currently a Withings scale | internal (`ha`) |

One Ollama instance serves the local models and stays internal. The models it holds are declared in its HelmRelease and pulled at container startup, and LiteLLM fronts them with an OpenAI-compatible API for clients that expect one. A three-instance CloudNativePG cluster named `postgres` runs Postgres in HA; its declared databases back Authentik, Paperless, Miniflux, and Open WebUI, and pgAdmin connects to it as a client.

## Security

Secrets use two mechanisms, both committed encrypted, never in plaintext:

- Host secrets use agenix, encrypted to each node's SSH host key, so a node decrypts its own secrets at boot with no shared passphrase. `secrets/secrets.nix` lists the recipients; the K3s join token, the router's Tailscale and AdGuard credentials, the wifi passphrase, and the kiosk dashboard URL live here.
- Kubernetes secrets use SOPS with age, and they are held in a separate private repository, `bedrock-secrets`, rather than in this one ([ADR 0060](docs/adr/0060-private-secrets-repo-per-cluster-keys.md)). Flux reconciles that repository as a second source through the `cluster-secrets` Kustomization and decrypts it in-cluster at reconcile time. Exactly one SOPS file remains here, `kubernetes/clusters/home/bootstrap-secrets/bedrock-secrets-git-auth.sops.yaml`, which carries the read-only deploy key for the private repository and is itself decrypted by the same cluster age key, so the age key stays the only irreducible root.

Editing secrets, re-keying them, and recovering them on a fresh cluster are covered in the [disaster recovery runbook](docs/disaster-recovery.md).

Several layers of defense-in-depth sit on top. The app namespaces run default-deny NetworkPolicies, so a pod reaches only what it is explicitly allowed to. Workloads run with a non-root, dropped-capability securityContext, and K3s encrypts Secrets at rest.

## Disaster recovery

The cluster is reproducible from this repository plus two seeds it cannot hold: the age key that decrypts the secrets and the host SSH keys.

There is no off-site copy of any cluster data. The object storage that held the backups went with the cloud account, and nothing replaced it ([ADR 0081](docs/adr/0081-retire-the-hetzner-account.md)), so the estate survives a lost disk or a lost node and does not survive the loss of the building. Postgres has no point-in-time recovery. What that means scenario by scenario, along with the full rebuild from total loss and the procedures for rehearsing recovery without an outage, is in the [disaster recovery runbook](docs/disaster-recovery.md).

Admission webhooks are a separate recovery path, because one that is unavailable rejects the very writes needed to repair it. Recognising that failure, relaxing enforcement, and restoring it afterwards are covered in the [admission break-glass runbook](docs/admission-break-glass.md).

## Continuous integration

Four workflows run on every pull request, covering four areas:

- The Nix side: formatting with `nixfmt`, linting with `statix` and `deadnix`, and `nix flake check` to evaluate every host configuration.
- The Kubernetes manifests: `kubeconform` against the upstream and CRD schemas, `kustomize build` over every kustomization, and a render of the per-app Kustomizations with their Flux post-build substitutions applied so an unresolved variable fails a pull request rather than a reconcile.
- Policy and alerting: the Kyverno policies run against their unit tests and against a first-party manifest, and the Prometheus alert rules are checked and unit-tested with `promtool`.
- Repository hygiene: a check that no SOPS file was committed unencrypted, a check that the ADR index matches the ADRs on disk, a check that every Helm source is both listed for deployment and referenced by a release, and a regeneration of `docs/inventory.md` that fails on drift. The Renovate configuration is validated on the same trigger.

One gate deliberately does not run in CI. `promtool` proves a rule parses and behaves as its fixture says, but the fixture supplies the series, so a rule selecting a metric name, a label value, or a bucket boundary that nothing in the estate emits passes exactly as a working rule does and then stays silent forever. Catching that needs the live series database, so `scripts/check-alert-selectors.sh` is run by an operator against the cluster rather than by a pull request runner that cannot reach it. The [alert selector audit](docs/alert-selector-audit.md) covers when to run it and what to do with each finding.

[Renovate](https://docs.renovatebot.com/) keeps `flake.lock`, Helm chart versions, and GitHub Actions current through automated pull requests.

## Roadmap

- Off-site backups again, once a NAS in the rack replaces the object storage that was retired with the cloud account.
- Broader alerting on top of the existing Prometheus and Grafana stack.

This is a personal setup that changes as needs change, so the roadmap is a direction rather than a commitment.

## Contributing

This is a personal homelab, not a product, but issues and forks are welcome. Anyone reusing the layout is encouraged to adapt it to their own hardware and domain.

To work on it locally, clone the repository and enter the dev shell with `nix develop`, then run `nix flake check` before opening a pull request. The Kubernetes manifest validation that runs in CI is `scripts/check-manifests.sh`, which runs the same way locally, alongside the other `scripts/check-*.sh` gates.

## Support

Open an issue on the [GitHub repository](https://github.com/lucawalz/bedrock/issues) for questions or problems.

## Authors and acknowledgment

Built and maintained by Luca Walz. It stands on a lot of open-source work, in particular NixOS, K3s, Flux, nixos-anywhere, disko, agenix, SOPS, Longhorn, Traefik, and the chart maintainers behind the services it runs.

## License

Released under the MIT License. See [`LICENSE`](LICENSE).

## Project status

Actively maintained and running in production at home.

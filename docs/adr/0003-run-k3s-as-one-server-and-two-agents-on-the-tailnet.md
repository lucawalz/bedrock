---
status: accepted
date: 2026-11-07
---

# 0003. Run K3s as one server and two agents on the tailnet

## Context

Three identical mini PCs have to carry the control plane, the workloads and the replicated storage. K3s ships defaults for ingress, load balancing, storage, DNS and metrics that would compete with the components this repository manages through Flux.

## Decision

- control-plane-1 is the only K3s server and runs the embedded etcd datastore. worker-1 and worker-2 are agents. All three schedule workloads and carry Longhorn disks.
- The server disables the bundled servicelb, Traefik, local-storage, CoreDNS and metrics-server. MetalLB, Traefik, Longhorn, CoreDNS and metrics-server are installed by Flux instead, so every one of them is versioned and reviewed in git. Secrets encryption at rest is on.
- Flannel uses VXLAN over `tailscale0` with an outer MTU of 1280, so pod traffic between nodes travels inside WireGuard. NetworkPolicy is enforced by the kube-router controller embedded in K3s.
- The server takes an etcd snapshot every 12 hours, keeps five, and uploads them to the `bedrock-etcd` bucket in Cloudflare R2 ([0012](0012-back-up-off-site-to-cloudflare-r2-and-test-restores.md)).
- Container images are pulled through the zot cache at `registry.syslabs.dev`, with the upstream registry configured as a fallback endpoint for each mirror.
- The inventory is parameterised for more servers. Pod CIDR allowlists in network policies span eight node slots, which covers a target of three control planes and three workers.

## Consequences

- control-plane-1 is a single point of failure for the API. Workloads already running keep serving while it is down, and recovery is a rebuild from the flake and the newest etcd snapshot.
- The cluster CA must survive a datastore wipe, or agents can no longer join with the pinned token ([0004](0004-keep-a-stable-cluster-ca-under-an-offline-root.md)).
- Encrypting pod traffic on a LAN path costs some throughput.
- On an empty cache zot fetches a large image fully before answering, which can outlast the containerd pull deadline. Pods back off and recover once the cache is warm.

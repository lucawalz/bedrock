---
status: accepted
date: 2026-07-25
---

# 0067. Cache upstream container images with an in-cluster pull-through registry

## Context

Every container image in the cluster came straight from its upstream registry, and nothing sat in between. The three nodes each pulled the same image independently, so a workload that moved or scaled fetched the same layers over the home uplink two or three times. The kubelet image garbage collector runs at a high threshold of 70 percent and a low threshold of 55 percent, set in `modules/k3s/estate.nix`, so images are evicted routinely and refetched later, which turns a one-time download into a recurring one. Rebuilding a node re-downloads its entire working set. Anonymous pulls from Docker Hub are rate limited per address, and the whole LAN shares one address, so a burst of reconciles could exhaust the budget for everything behind the router.

The failure mode is worse than slow. When an upstream registry is unreachable or rate limits a pull, the affected pods sit in `ImagePullBackOff` until the limit resets, and there is no local copy to fall back on. Four registries account for effectively all traffic: `docker.io`, `ghcr.io`, `quay.io`, and `registry.k8s.io`.

## Decision

Run [zot](https://zotregistry.dev) in the cluster as a pull-through cache for those four registries and point every node's containerd at it. Zot is delivered by its upstream Helm chart through a `HelmRelease` under its own Kustomization, matching how the rest of the infrastructure layer is delivered. Its `sync` extension is configured `onDemand` for the four upstreams, so a repository is fetched the first time it is requested and served locally afterwards, and each upstream maps to its own destination namespace inside zot, which is what lets one registry front four without repository names colliding.

The cache is reachable at `registry.syslabs.dev` through Traefik rather than through a LoadBalancer address of its own. The `dmz-pool` MetalLB pool is a single address that the Traefik Service already consumes, so a second LoadBalancer Service would stay pending indefinitely, and Traefik already serves the wildcard certificate as its default, so the route needs no Certificate of its own and containerd sees a publicly trusted chain. The route carries no forward-auth middleware: forward auth answers an unauthenticated request with a redirect to the identity provider, and containerd follows neither the redirect nor the browser flow behind it, so attaching the middleware would break every pull. Traefik imposes no request body size limit by default and its write timeout defaults to zero, so streaming a multi-gigabyte layer back to a node has no cap.

Node configuration lands in `environment.etc."rancher/k3s/registries.yaml"` in `modules/k3s/common.nix`, which both the server and agent modules import, so one declaration reaches all three nodes and no other host. Each of the four mirrors lists two endpoints, the cache first and the real upstream second, and each carries a rewrite that prefixes the repository with the upstream host name, because that is the path zot stores it under.

The second endpoint is what keeps a cold cluster bootable. K3s compares the last endpoint of a mirror against containerd's implicit default endpoint for that registry, and when they match it moves that endpoint into the `server` fallback line of the generated `hosts.toml` instead of leaving it in the host list. Rewrites attach to host entries and never to the fallback, so the upstream is tried with the original, unrewritten repository name; without that behaviour the rewrite would follow the fallback and ask Docker Hub for a repository that does not exist. The circularity this resolves is real, because zot's own image comes from one of the cached upstreams, so the first pull after a cold start is a pull of the cache through the cache. It fails against the cache, falls through to the upstream, and the cluster comes up.

Storage is a `longhorn-disposable` volume, single replica with a Delete reclaim policy. Every byte in it is a copy of something that still exists upstream, so replicating it three times would spend real disk on data that costs nothing to refetch, and losing it costs only the next few pulls.

## Options considered

- Zot in-cluster behind Traefik, chosen. It reuses the ingress, the wildcard certificate, and the storage that already exist, it is delivered the same way as every other controller, and its `sync` extension covers all four upstreams from one deployment.
- A separate LoadBalancer address for the cache. Rejected: `dmz-pool` holds exactly one address and Traefik has it, and widening the pool would mean reworking the VLAN 20 address plan agreed in [0016](0016-concrete-zoned-ip-scheme.md) for a service that has no reason to bypass the ingress.
- The registry cache on the router or a node outside Kubernetes. Rejected because it would put a stateful service outside the GitOps and backup model established in [0002](0002-nixos-flakes-flux-gitops.md), and the router is the one host in the estate whose failure takes the whole network with it.
- Four separate `registry:2` mirror deployments, one per upstream. Rejected as four times the objects, four times the storage, and four hostnames, to do what zot does in one deployment.
- K3s's embedded distributed registry mirror, Spegel. Rejected because it shares images between nodes that already hold them rather than caching upstream, so it does nothing for the first pull, for a rebuilt node, or for a rate limit.

## Consequences

Repeat pulls of an image any node has already fetched are served from the LAN. The Docker Hub rate limit is consumed once per image instead of once per node, and an upstream outage stops being an immediate cluster problem for anything already cached. Cold starts are unaffected, because the fallback endpoint keeps working when the cache does not.

The sharpest cost is operational. `registries.yaml` is read by containerd at startup, so changing it requires restarting k3s on each node, which restarts containerd and therefore every pod on that node. That is a node-drain-scale operation rather than a config reload, and it is why any change to it is sequenced one node at a time with the control plane last, since rebuilding the control-plane node restarts the API server and doing that while a worker is mid-drain leaves the drain in an unknown state.

The cache is also on the pull path for the whole cluster. It is a single replica on disposable storage, so when it is down every pull takes the fallback path and pays one failed connection first, which is a latency cost rather than an outage and is what buys not having to make the cache highly available.

The cache does not evict on its own, and getting the bound wrong twice left two lessons worth keeping:

- A retention rule that cannot be evaluated is an absent one, not a conservative default. The first policy kept anything pushed within the last thirty days or among the most recently pulled, but pull timestamps require a metadata database this deployment does not enable, so the pull-based criteria could never match. Retention criteria combine with OR, so the one satisfiable criterion retained every blob in a cache that fills in six weeks, which is all of it. The policy is now a single most-recently-pushed count, which bounds the cache by structure and depends on no optional subsystem.
- Longhorn charges for declared size, not written bytes. The volume was raised to 80Gi while the cache was still unbounded and never revisited once the bound took effect, even though the bounded cache settles at a couple of gigabytes. The cost was not disk but a permanent claim on some node's scheduling budget, which [0086](0086-thin-provision-longhorn-and-detect-what-cannot-be-derived.md) records as a contributor to the scheduling ceiling. It is now 20Gi, several times the settled working set, resized by recreating the volume, which Longhorn requires because it expands but does not shrink and which is in any case the correct operation for a volume that is disposable by design.

Filling the volume was also invisible while it happened, because the Longhorn alerts count space promised to replicas rather than bytes written. A pair of `PersistentVolumeFillingUp` and `PersistentVolumeAlmostFull` alerts now read `kubelet_volume_stats`, so any claim that fills is visible before it breaks something, and the one workload that a failed pull took down during the first incident sets `RollingUpdate` explicitly, so a pull that cannot be satisfied leaves the running pod in place. The decision to run a pull-through cache is unchanged; what changed is that its capacity is managed by the cache itself rather than by remembering to intervene.

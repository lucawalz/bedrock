---
status: accepted
date: 2026-07-25
---

# 0067. Cache upstream container images with an in-cluster pull-through registry

## Context

Every container image in the cluster came straight from its upstream registry, and nothing sat in between. The three nodes each pulled the same image independently, so a workload that moved or scaled fetched the same layers over the home uplink two or three times. The kubelet image garbage collector runs at a high threshold of 70 percent and a low threshold of 55 percent, set in `modules/k3s/common.nix`, so images are evicted routinely and refetched later, which turns a one-time download into a recurring one. Rebuilding a node re-downloads its entire working set. Anonymous pulls from Docker Hub are rate limited per address, and the whole LAN shares one address, so a burst of reconciles could exhaust the budget for everything behind the router.

The failure mode is worse than slow. When an upstream registry is unreachable or rate limits a pull, the affected pods sit in `ImagePullBackOff` until the limit resets, and there is no local copy to fall back on. Four registries account for effectively all traffic: `docker.io`, `ghcr.io`, `quay.io`, and `registry.k8s.io`.

## Decision

Run [zot](https://zotregistry.dev) in the cluster as a pull-through cache for those four registries and point every node's containerd at it.

Zot is delivered by its upstream Helm chart through a `HelmRelease`, matching how the rest of the infrastructure layer is delivered, and lives under `kubernetes/infrastructure/controllers/onprem/zot/` next to traefik, metallb, longhorn, and the cloudflare tunnel. Its `sync` extension is configured `onDemand` for the four upstreams, so a repository is fetched the first time it is requested and served locally afterwards. Each upstream maps to its own destination namespace inside zot, which is what makes one registry able to front four without repository names colliding.

The cache is reachable at `registry.syslabs.dev` through Traefik rather than through a LoadBalancer address of its own. The `dmz-pool` MetalLB pool is a single address, 10.20.0.50/32, and the Traefik Service already consumes it, so a second LoadBalancer Service would stay pending forever. Traefik also already serves the `*.syslabs.dev` wildcard certificate as its default certificate, so the route needs no Certificate of its own and containerd sees a publicly trusted chain. The route is bound to the `websecure` entrypoint only. It deliberately carries no authentik forward-auth middleware: forward auth answers an unauthenticated request with a redirect to the identity provider, and containerd follows neither the redirect nor the browser flow behind it, so attaching the middleware would break every pull. Traefik imposes no request body size limit by default, and its `writeTimeout` defaults to zero, so streaming a multi-gigabyte layer back to a node has no cap.

Node configuration lands in `environment.etc."rancher/k3s/registries.yaml"` in `modules/k3s/common.nix`, which both `modules/k3s/server.nix` and `modules/k3s/agent.nix` import, so one declaration reaches all three nodes and no other host. Each of the four mirrors lists two endpoints, the cache first and the real upstream second, plus a rewrite that prefixes the repository with the upstream host name, because that is the path zot stores it under.

The second endpoint is what keeps a cold cluster bootable, and the mechanism is worth stating precisely. k3s compares the last endpoint of a mirror against containerd's implicit default endpoint for that registry, and when they match it moves that endpoint into the `server` fallback line of the generated `hosts.toml` instead of leaving it in the host list. Rewrites are attached to host entries and never to the `server` fallback, so the upstream is tried with the original, unrewritten repository name. Without that behaviour the rewrite would follow the fallback and ask Docker Hub for `docker.io/library/nginx`, which does not exist. The circularity this resolves is real: zot's own image comes from `ghcr.io`, so the first pull after a cold start is a pull of the cache through the cache. It fails against `registry.syslabs.dev`, falls through to `ghcr.io`, and the cluster comes up.

Storage is a 50Gi `longhorn-disposable` volume, single replica with a Delete reclaim policy. Every byte in it is a copy of something that still exists upstream, so replicating it three times would spend real disk on data that costs nothing to refetch, and losing it costs only the next few pulls.

## Options considered

- Zot in-cluster behind Traefik, chosen. It reuses the ingress, the wildcard certificate, and the storage that already exist, it is delivered the same way as every other controller, and its `sync` extension covers all four upstreams from one deployment.
- A separate LoadBalancer address for the cache. Rejected on facts rather than taste: `dmz-pool` holds exactly one address and Traefik has it. Widening the pool would mean reworking the VLAN 20 address plan agreed in [0016](0016-concrete-zoned-ip-scheme.md) for a service that has no reason to bypass the ingress.
- The registry cache on the router or a node outside Kubernetes. Rejected because it would put a stateful service outside the GitOps and backup model established in [0002](0002-nixos-flakes-flux-gitops.md), and the router is the one host in the estate whose failure takes the whole network with it.
- Four separate `registry:2` mirror deployments, one per upstream. Rejected as four times the objects, four times the storage, and four hostnames, to do what zot does in one deployment.
- k3s's embedded distributed registry mirror, Spegel. Rejected because it shares images between nodes that already hold them rather than caching upstream, so it does nothing for the first pull, for a rebuilt node, or for a rate limit.

## Consequences

Repeat pulls of an image any node has already fetched are served from the LAN, the Docker Hub rate limit is consumed once per image instead of once per node, and an upstream outage stops being an immediate cluster problem for anything already cached. Cold starts are unaffected because the fallback endpoint keeps working when the cache does not.

Three costs follow. The first is operational and is the sharpest: `registries.yaml` is read by containerd at startup, so changing it requires restarting k3s on each node, which restarts containerd and therefore every pod on that node. This is a node-drain-scale operation, not a config reload, and it is the reason the rollout below is sequenced one node at a time with the control plane last.

The second is that the cache is now on the pull path for the whole cluster. It is a single replica on disposable storage, so when it is down every pull takes the fallback path and pays one failed connection first. That is a latency cost, not an outage, and it is the deliberate trade for not needing the cache to be highly available.

The third is that the cache grows without bound. Nothing evicts a cached repository, so the volume fills over time and pulls then fall back to upstream. Because the volume is disposable by design, the remedy is to delete the `data-zot-0` PersistentVolumeClaim and let the StatefulSet recreate it, or to expand it, since `longhorn-disposable` allows volume expansion.

## Implementation

Roll out in this order, after the manifests are pushed and Flux has reconciled the zot HelmRelease to ready. The router goes first so that `registry.syslabs.dev` resolves before any node is told to use it; otherwise every pull pays a DNS failure before falling back.

1. Confirm the cache is serving: `kubectl -n zot get statefulset zot` shows one ready replica, and `curl -s https://registry.syslabs.dev/v2/_catalog` from the LAN returns a JSON body.
2. Rebuild the router: `nixos-rebuild switch --flake .#router --target-host root@10.20.0.1`, then confirm the rewrite answers with `dig +short registry.syslabs.dev @10.20.0.1`, which must return 10.20.0.50.
3. For worker-1, then worker-2, then master, one at a time and only after the previous node reports Ready:
   - `kubectl cordon <host>`
   - `kubectl drain <host> --ignore-daemonsets --delete-emptydir-data --timeout=15m`
   - `nixos-rebuild switch --flake .#<host> --target-host root@<ip>` with 10.20.0.11 for worker-1, 10.20.0.12 for worker-2, and 10.20.0.10 for master
   - `kubectl wait --for=condition=Ready node/<host> --timeout=15m`
   - `kubectl uncordon <host>`
   - confirm `ssh root@<ip> cat /var/lib/rancher/k3s/agent/etc/containerd/certs.d/docker.io/hosts.toml` lists `registry.syslabs.dev` as a host with a rewrite block and `registry-1.docker.io` as the `server` line
4. Master is last because rebuilding it restarts the API server for roughly thirty seconds, and doing that while a worker is mid-drain leaves the drain in an unknown state.

Verify the cache is actually serving rather than merely reachable. On worker-1, pull a tag no node holds, for example `ssh root@10.20.0.11 k3s crictl pull docker.io/library/alpine:3.21`. Then confirm it landed in the cache with `curl -s https://registry.syslabs.dev/v2/_catalog`, which must now list `docker.io/library/alpine`. Then pull the same tag on worker-2 and check the zot logs with `kubectl -n zot logs statefulset/zot`, which must show the manifest served without a new upstream sync for that repository.

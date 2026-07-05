---
status: accepted
date: 2026-07-06
---

# 0058. Split cluster-infrastructure into focused Flux Kustomizations

## Context

The whole infrastructure layer of the home cluster reconciled through a single Flux Kustomization named `cluster-infrastructure`, pointed at `./kubernetes/clusters/home/infrastructure`. That one object built every infrastructure concern at once: storage, networking, monitoring, and security. The convenience of a single entry point came with a single failure domain. A `wait: true` Kustomization does not report ready until every object it builds is healthy, so a stalled HelmRelease anywhere in the tree held the entire infrastructure layer in a not-ready state, and anything downstream that depended on it waited behind the slowest or most broken component. A bad chart bump in monitoring could keep storage from being reported healthy even though storage itself was fine. The blast radius of any one reconcile problem was the whole layer.

The concerns bundled into that Kustomization are genuinely independent. Storage is Longhorn, MinIO, Velero, and the external snapshotter. Networking is cert-manager, MetalLB, Traefik, and the Cloudflare tunnel. Monitoring is the kube-prometheus-stack, Loki, Tempo, and Alloy. Security is Kyverno, its policy reporter, and Reloader. None of these needs the others to reconcile, and grouping them under one Kustomization coupled their fates for no reason other than history.

Splitting them is safe to describe but delicate to execute. Flux tracks ownership of every object it applies through inventory labels on the managing Kustomization. Narrowing `cluster-infrastructure` so that it no longer builds the storage, networking, monitoring, and security subtrees would, with pruning left on, read those objects as removed from its inventory and garbage-collect them, deleting live Longhorn, Traefik, and Prometheus releases in the process. The migration therefore had to hand ownership across without ever presenting an interval where a running object belonged to no Kustomization and was eligible for pruning.

## Decision

Split `cluster-infrastructure` into four focused Flux Kustomizations, one per concern: `cluster-storage`, `cluster-networking`, `cluster-monitoring`, and `cluster-security`, defined in `kubernetes/clusters/home/config/`. Each points at its own subtree under `kubernetes/clusters/home/infrastructure/`, carries the same `dependsOn` on sources, secrets, and namespaces that the monolith had, and keeps `wait: true` so its readiness now reflects only its own area. A failure in monitoring holds monitoring not-ready and leaves storage, networking, and security free to reconcile and report healthy on their own. What remains of `cluster-infrastructure` narrows to the concerns that were not carved out, the databases, notifications, Rancher, and delivery subtrees, which continue to reconcile as before.

Carry out the split as a deliberate two-step migration so no running object is ever deleted. First, add the four new Kustomizations, remove the four subtrees from the root infrastructure kustomization so `cluster-infrastructure` stops claiming them, and set `cluster-infrastructure` to `prune: false` for the duration of the handover. With pruning disabled, dropping the subtrees from its scope orphans nothing: the objects stay running and the new Kustomizations adopt them into their own inventories on the next reconcile. Once ownership has transferred cleanly and the four new Kustomizations report healthy over the resources they now own, re-enable `prune: true` on `cluster-infrastructure` in a second commit. The fourteen HelmReleases across the four subtrees, Longhorn among them, moved with zero deletions and no workload disruption.

## Options considered

- Keep the single `cluster-infrastructure` Kustomization. This is the status quo and needs no migration, but it is the source of the problem: one shared readiness gate and one shared failure domain across four unrelated concerns, so a single reconcile failure stalls the whole infrastructure layer and can cascade to anything waiting on it. The coupling buys nothing that four Kustomizations do not also provide.
- Split into four Kustomizations with a delete-and-recreate cutover. Removing the subtrees from `cluster-infrastructure` with pruning left on, then letting the new Kustomizations rebuild them, reaches the same end state in one step. It also deletes and recreates live Longhorn, Traefik, and Prometheus releases, which means storage detachment, ingress interruption, and lost monitoring state for the duration of the recreate, for a reorganisation that changes no desired state. The risk is unacceptable for a reshuffle that should be invisible.
- Split with the `prune: false` adopt-then-reprune migration. Disabling pruning on `cluster-infrastructure` during the handover lets the new Kustomizations adopt the running objects before anything can be garbage-collected, and re-enabling pruning afterward restores the safety of drift correction. This is the chosen path: it reaches the same clean four-way split with no window in which a live object is eligible for deletion.

## Consequences

A reconcile failure in one infrastructure concern is now contained to that concern. A stalled monitoring chart holds `cluster-monitoring` not-ready and leaves storage, networking, and security to reconcile and report healthy independently, which shrinks the blast radius of any single problem from the whole layer to one quarter of it and makes the source of a stall obvious from which Kustomization is failing rather than which object inside one large one.

The cost is more objects to reason about. Where there was one infrastructure Kustomization there are now five, and a reader tracing what manages a given release consults the per-concern Kustomization rather than a single catch-all. The `dependsOn` edges are duplicated across the four new definitions instead of declared once. This is a deliberate trade of a little more surface for a lot less coupling, and the surface is uniform: the four definitions are identical but for their name and path.

The adopt-then-reprune sequence is now the template for safely re-homing any Flux-managed resource. Whenever ownership of live objects must move from one Kustomization to another, disabling pruning on the losing Kustomization for the duration of the handover, letting the gaining Kustomization adopt the objects, and re-enabling pruning once the transfer is confirmed is the pattern that guarantees no running workload is deleted in the process.

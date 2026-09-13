---
status: accepted, Kustomization names superseded, successor unrecorded
date: 2026-07-06
---

# 0058. Split cluster-infrastructure into focused Flux Kustomizations

## Context

The whole infrastructure layer of the home cluster reconciled through a single Flux Kustomization named `cluster-infrastructure`, which built storage, networking, monitoring, and security at once. The convenience of one entry point came with a single failure domain: a `wait: true` Kustomization does not report ready until every object it builds is healthy, so a stalled HelmRelease anywhere in the tree held the entire infrastructure layer not-ready and anything downstream waited behind the slowest or most broken component. A bad chart bump in monitoring could keep storage from being reported healthy even though storage was fine. The concerns bundled together are independent and none needs the others to reconcile, so grouping them coupled their fates for no reason other than history. Splitting them is safe to describe but delicate to execute. Flux tracks ownership of every object it applies through inventory labels on the managing Kustomization. Narrowing `cluster-infrastructure` so that it no longer built those subtrees would, with pruning left on, read the objects as removed from its inventory and garbage-collect them, deleting live Longhorn, Traefik, and Prometheus releases in the process. The migration therefore had to hand ownership across without ever presenting an interval where a running object belonged to no Kustomization and was eligible for pruning.

## Decision

Split `cluster-infrastructure` into four focused Kustomizations, one per concern, each pointing at its own subtree, carrying the same `dependsOn` on sources, secrets, and namespaces that the monolith had, and keeping `wait: true` so its readiness reflects only its own area. A failure in monitoring holds monitoring not-ready and leaves storage, networking, and security free to reconcile and report healthy. What remains of `cluster-infrastructure` narrows to the concerns not carved out.

Carry out the split as a two-step migration so no running object is ever deleted. First, add the four new Kustomizations, remove the four subtrees from the root infrastructure kustomization so `cluster-infrastructure` stops claiming them, and set it to `prune: false` for the duration of the handover. With pruning disabled, dropping the subtrees orphans nothing: the objects stay running and the new Kustomizations adopt them into their own inventories on the next reconcile. Once ownership has transferred cleanly and the new Kustomizations report healthy over the resources they own, re-enable `prune: true` in a second commit. Every HelmRelease across the four subtrees, Longhorn among them, moved with zero deletions and no workload disruption.

## Options considered

- Keep the single `cluster-infrastructure` Kustomization. The status quo, needing no migration, but it is the source of the problem: one shared readiness gate and one shared failure domain across unrelated concerns, buying nothing that separate Kustomizations do not also provide.
- Split with a delete-and-recreate cutover. Removing the subtrees with pruning left on reaches the same end state in one step, but it deletes and recreates live Longhorn, Traefik, and Prometheus releases, which means storage detachment, ingress interruption, and lost monitoring state for a reorganisation that changes no desired state.
- Split with the `prune: false` adopt-then-reprune migration, chosen. Disabling pruning during the handover lets the new Kustomizations adopt the running objects before anything can be garbage-collected, and re-enabling it afterward restores drift correction, with no window in which a live object is eligible for deletion.

## Consequences

A reconcile failure in one infrastructure concern is contained to that concern, which shrinks the blast radius of any single problem and makes a stall easier to locate, because the failing Kustomization names the area. The cost is more objects to reason about and `dependsOn` edges duplicated across definitions instead of declared once. That trades a little more surface for a lot less coupling, and the surface is uniform, since the definitions are identical but for their name and path. The adopt-then-reprune sequence is now the template for safely re-homing any Flux-managed resource: disable pruning on the losing Kustomization for the duration of the handover, let the gaining one adopt the objects, and re-enable pruning once the transfer is confirmed.

The four names this record chose no longer describe the cluster. They were dissolved the day after the split, when `kubernetes/clusters/home/config/` was re-sorted into base, profiles, fleet and home layers, and the concerns were redistributed across a larger set of Kustomizations, several of them per-application. The principle decided here was not reversed but taken further: each independent concern still owns its own Kustomization and its own readiness gate, and the adopt-then-reprune pattern remains the migration template. What is missing is a record of the layering that replaced these names, which no ADR currently covers.

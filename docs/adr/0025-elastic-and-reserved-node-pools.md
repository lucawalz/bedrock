---
status: superseded by 0041
date: 2026-06-15
---

# 0025. Split burst capacity into elastic and reserved node pools

## Context

[0024](0024-autoscaler-owned-burst-pool.md) handed the single `burst-workers` MachineDeployment to the cluster-autoscaler so pending-pod pressure could grow and shrink it on its own. That covers demand-driven capacity, but it leaves no place for nodes that should exist on a schedule rather than in response to pressure: a pool an operator pins up by hand for a planned batch run or a maintenance window, holds at a fixed size, and pins back down when the work is done. Folding both behaviours into one pool is a contradiction, because the autoscaler treats every node it discovers as fungible and will drain a hand-pinned node the moment it looks idle. The two scaling authorities need two pools.

## Decision

The cluster runs two named worker pools against the same `burst` Cluster, distinguished by the `horizon.dev/pool-type` label on the MachineDeployment and the `horizon.dev/pool` node label the bootstrap config stamps on each node.

The `elastic` pool is the renamed pool from [0024](0024-autoscaler-owned-burst-pool.md). Its MachineDeployment `elastic-workers` carries no `spec.replicas`, keeps the `cluster.x-k8s.io/cluster-name: burst` label and the autoscaler min and max-size annotations of zero and two, and is the only pool the autoscaler discovers and owns. Its nodes carry `horizon.dev/pool=elastic`.

The `reserved` pool is new. Its MachineDeployment `reserved-workers` carries no autoscaler annotations, so the autoscaler ignores it entirely, and commits `spec.replicas: 0` as its created-with floor. horizon scales it by hand during a planned run. Its nodes carry `horizon.dev/pool=reserved`.

Both pools share one `HCloudMachineTemplate` named `worker` for an identical VM shape, and each has its own `KThreesConfigTemplate` so the node label differs per pool. Flux must create `reserved-workers` once but never correct horizon's live replica count, so the MachineDeployment carries `kustomize.toolkit.fluxcd.io/ssa: IfNotPresent`. Under Flux 2.8, that value applies the resource only when it is absent and leaves it untouched on every later pass, so a hand-set replica count survives reconciliation.

## Options considered

- Two pools split by `pool-type`, with `elastic` autoscaled and `reserved` operator-pinned, chosen. Each scaling authority owns exactly one pool, and the autoscaler never touches a pinned node because the reserved pool has no autoscaler annotations to discover it by.
- One pool with taints or annotations marking some nodes as protected. The autoscaler still treats the MachineDeployment as a single scalable group, so a protected node and an elastic node share one replica count and one scale-down decision, which is the contradiction this record exists to remove.
- A reserved pool pinned in git with no SSA opt-out. Flux would revert every hand scale to the committed floor on the next pass, the same two-controller conflict [0024](0024-autoscaler-owned-burst-pool.md) resolved for the elastic pool, so each scale event would require a commit and a reconcile.

## Consequences

The autoscaler owns the elastic pool and horizon owns the reserved pool, and neither reaches into the other. The reserved replica count is not recorded in git, so its live size must be read from the cluster; the committed manifest records only the floor of zero. The `IfNotPresent` strategy means a committed change to any other field of `reserved-workers` after first creation will not reconcile either, so a genuine spec change to the reserved pool requires deleting the live object and letting Flux recreate it. The `worker` template is shared, so a VM-shape change applies to both pools at once, which is intended.

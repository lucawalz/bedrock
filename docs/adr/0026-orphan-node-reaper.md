---
status: superseded by 0041 and 0071
date: 2026-06-15
---

# 0026. Prune orphan burst node objects with an in-cluster reaper

## Context

The burst pools from [0024](0024-autoscaler-owned-burst-pool.md) and [0025](0025-elastic-and-reserved-node-pools.md) scale to zero. When the elastic pool drained under autoscaler pressure, or an operator pinned the reserved pool back down, CAPH deleted the Hetzner server promptly but the corresponding Kubernetes Node object did not always leave with it. The owning Machine was gone, so nothing reconciled the stale Node, and it lingered `NotReady` with its DaemonSet pods stuck in `Terminating`. CAPI core does run node deletion on Machine teardown, but for this externally managed burst cluster that step did not reliably complete on an abrupt scale-down, so the residue accumulated across cycles and cluttered scheduling state and dashboards.

The control-plane node and the home workers must never be at risk from any automated pruning. They carry no `horizon.dev/pool` label, which gives a clean predicate that excludes them by construction.

## Decision

A `node-reaper` CronJob runs every ten minutes in `caph-system` and deletes only Node objects that are simultaneously stale, burst-pool, and unowned: labelled as an elastic or reserved pool node, not `Ready`, and referenced by no Machine in any namespace. The job fails safe. It builds the owned set from a single cluster-wide Machine listing, and if that listing errors it exits non-zero and deletes nothing, because acting on a partial owned set could remove a node that still belongs to a live Machine. A run with no candidates is a no-op, and deletes do not wait so one stuck node cannot stall the rest. Tailscale device cleanup is left entirely to Tailscale, since burst nodes register as ephemeral devices that Tailscale removes once they go offline, so the reaper never touches the Tailscale API.

## Options considered

- An in-cluster CronJob with a fail-safe predicate, chosen. It needs no extra controller, the deletion rule is auditable in a few lines of shell, and the label predicate makes it impossible to touch a control-plane or home worker node.
- A custom controller watching Node and Machine objects. It would react faster than a ten-minute poll, but it is far more code and operational surface for a tidy-up that has no latency requirement.
- Relying on CAPI core node deletion alone. This is the behaviour that already failed to complete for the abrupt scale-down of an externally managed cluster, which is the gap this record filled.

## Consequences

Orphan burst nodes cleared within ten minutes of a scale-down without operator action, and control-plane-1, worker-1, and worker-2 were excluded by construction because they carry no pool label. The narrowing this record's successors describe was recorded but never carried out: the Node-deletion pass stayed in the manifest through the autoscaler's retirement in [0062](0062-retire-elastic-cluster-autoscaler.md) and kept running every ten minutes against reserved-pool nodes with nothing left provisioning them. [0071](0071-deploy-horizon-operator-from-published-chart.md) removes it, because orphan Node collection belongs to the horizon operator, which knows each node's registration window and so cannot delete one that is still joining. The CronJob keeps only the Longhorn pass from [0040](0040-reap-orphaned-longhorn-nodes.md) and is renamed accordingly, so nothing of this record's decision remains in the estate.

---
status: accepted
date: 2026-06-15
---

# 0026. Prune orphan burst node objects with an in-cluster reaper

## Context

The burst pools from [0024](0024-autoscaler-owned-burst-pool.md) and [0025](0025-elastic-and-reserved-node-pools.md) scale to zero. When the elastic pool drains under autoscaler pressure, or an operator pins the reserved pool back down, CAPH deletes the Hetzner server promptly but the corresponding Kubernetes Node object does not always leave with it. The owning Machine is gone, so nothing reconciles the stale Node, and it lingers `NotReady` with its DaemonSet pods stuck in `Terminating`. CAPI core does run node deletion on Machine teardown, but for this externally managed burst cluster that step does not reliably complete on an abrupt scale-down, so the residue accumulates across cycles and clutters scheduling state and dashboards.

The control-plane nodes and the three home workers must never be at risk from any automated pruning. They carry no `horizon.dev/pool` label, which gives a clean predicate that excludes them by construction.

## Decision

A `node-reaper` CronJob runs every ten minutes in `caph-system` and deletes only Node objects that are simultaneously stale, burst-pool, and unowned.

A node is deleted only when all three hold:

- it carries `horizon.dev/pool` with a value of `elastic` or `reserved`,
- its `Ready` condition status is not `True` (`NotReady` or `Unknown`),
- no Machine in any namespace references it through `status.nodeRef.name`.

The job fails safe. It builds the owned set from a single `kubectl get machines -A` query, and if that query errors it exits non-zero and deletes nothing, because acting on a partial owned set could remove a node that still belongs to a live Machine. A run with no candidates is a no-op. Deletes use `--wait=false` so one stuck node cannot stall the rest.

The ServiceAccount holds a least-privilege ClusterRole: `nodes` get, list, delete on the core group, and `machines` get, list on `cluster.x-k8s.io`, and nothing else. The container runs non-root with a read-only root filesystem, all capabilities dropped, and the `RuntimeDefault` seccomp profile. The image is `alpine/k8s:1.35.2`, which bundles a kubectl matching the cluster's k3s v1.35.2 minor and a busybox shell with `awk` and `grep`, and pulls reliably from Docker Hub.

Tailscale device cleanup is left entirely to Tailscale. The burst nodes register as ephemeral devices, which Tailscale auto-removes once they go offline, so the reaper never touches the Tailscale API and the cluster never tampers with tailnet state.

## Options considered

- An in-cluster CronJob with a fail-safe predicate, chosen. It needs no extra controller, the deletion rule is auditable in a few lines of shell, and the label predicate makes it impossible to touch a control-plane or home worker node.
- A custom controller watching Node and Machine objects. It would react faster than a ten-minute poll, but it is far more code and operational surface for a tidy-up that has no latency requirement.
- Relying on CAPI core node deletion alone. This is the behaviour that already fails to complete for the abrupt scale-down of an externally managed cluster, which is the gap this record fills.

## Consequences

Orphan burst nodes clear within ten minutes of a scale-down without operator action, and master, worker-1, and worker-2 are excluded by construction because they carry no pool label. The reaper never deletes a `Ready` node, an unlabelled node, or a node still owned by a Machine, and a failed Machine listing blocks all deletion for that run. The poll interval bounds the lag, so a node can sit stale for up to ten minutes before pruning, which is acceptable for cleanup. The kubectl image tag is pinned to the cluster minor and must be bumped alongside a k3s upgrade.

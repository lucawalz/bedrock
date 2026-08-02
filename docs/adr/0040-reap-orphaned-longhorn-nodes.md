---
status: accepted
date: 2026-06-19
---

# 0040. Finalize orphaned Longhorn nodes in the burst node reaper

## Context

The reaper from [0026](0026-orphan-node-reaper.md) deletes stale Kubernetes Node objects for the elastic and reserved burst pools after a scale-down. Longhorn from [0005](0005-longhorn-storage.md) keeps its own `nodes.longhorn.io` record for every cluster node. Longhorn's node controller removes that record once the backing Kubernetes Node is gone, but only when the record's `spec.allowScheduling` is false. A node that leaves the cluster while still schedulable leaves the Longhorn record stranded. That is the normal burst scale-down path, and exactly the state the reaper produces when it deletes the Kubernetes Node. Longhorn's admission webhook then refuses to delete it, reporting the node ready condition false with reason `KubernetesNodeGone`, schedulable true, and zero replicas. The node's instance manager record sits in an `error` state.

For each stranded record `longhorn-manager` logs a warning on every reconcile. On this cluster seven decommissioned reserved-worker records accumulated across scale-down cycles and produced roughly 140 warning lines every five minutes across the manager pods, which tripped the log error-rate alert. The records were inert. All volumes stayed attached and healthy and no replicas lived on the dead nodes, so the cost was log noise, a false alert, and clutter in storage state. Clearing a record by hand by setting `allowScheduling` false let Longhorn reap it immediately, which confirmed the mechanism.

## Decision

The `node-reaper` CronJob gains a second pass that finalizes stranded Longhorn nodes. After the Kubernetes Node deletion pass it lists every `nodes.longhorn.io` record, skips any whose backing Kubernetes Node still exists, and for the remainder sets `spec.allowScheduling` to false. Longhorn's own controller then removes the record and cascades its instance manager.

The reaper never deletes a Longhorn node directly. Longhorn keeps enforcing its zero-replica safety check before it removes a record, and no replica eviction is forced, so a record that still holds replicas is left for Longhorn to drain and reap on its own. The existence check on the backing Kubernetes Node excludes the control plane and the three home workers by construction. It also protects a node that is only briefly unreachable, since a transient outage leaves the Kubernetes Node object in place. If the Longhorn list call fails the job logs the error and skips the storage pass without failing, so a Longhorn outage cannot block the Kubernetes Node pruning that 0026 owns.

The service account gains a namespaced Role in `longhorn-system` granting get, list, and patch on `longhorn.io` nodes, and nothing else. The existing cluster-scoped grant for core `nodes` get and list already covers the backing-node existence check.

## Options considered

- Extend the existing reaper, chosen. The reaper already owns burst-node cleanup, and it already runs on a fail-safe schedule for both the autoscaler-driven elastic path and the operator-driven reserved path. The storage cleanup rides the same job with no new component and no new latency requirement.
- A Longhorn cleanup step inside the horizon scale-down. It would act sooner for operator-driven removals, but it never runs for autoscaler-driven elastic scale-down or for a node that crashes out, both of which strand Longhorn records the same way. It would also couple a provider-agnostic CLI to Longhorn.
- A dedicated controller watching Node and Longhorn node objects. It reacts faster than a ten-minute poll but is far more code and operational surface for a tidy-up with no latency requirement, the same reasoning the reaper recorded in 0026.

## Consequences

Stranded Longhorn nodes and their instance manager records clear within one reaper interval of a scale-down without operator action, the warning stream stops, and the alert that surfaced the problem stops firing on it. The reaper now reads and patches `longhorn.io` nodes, a small widening of its blast radius. It is bounded to setting one boolean false on records whose backing Kubernetes Node is already gone, so a live or briefly-unreachable node is never touched. The reaper depends on the `longhorn.io` API being reachable for the storage pass, and degrades to a logged skip when it is not. The poll interval bounds the lag, so a record can sit stranded for up to ten minutes before it is finalized, which is acceptable for cleanup.

## Update 2026-08-02

This pass is the only one left. [0071](0071-deploy-horizon-operator-from-published-chart.md) gives Node deletion to the horizon operator and strips the Kubernetes Node pass from the CronJob, which is renamed from `node-reaper` to `longhorn-node-finalizer` to match what it does. The decision here is unaffected: the finalize logic, the schedule, the zero-replica safety left to Longhorn, and the degrade-to-skip behaviour on a Longhorn outage are all unchanged.

Two details in this record are now stale. The pass no longer runs after a Node deletion pass, so the state it corrects is produced by the horizon operator rather than by the reaper itself, which is the case the first option weighed here already anticipated for crashed and autoscaler-driven nodes. The cluster-scoped grant on core `nodes` narrows from get, list, and delete to get, since the backing-node existence check is all that still uses it.

---
status: accepted
date: 2026-06-19
---

# 0040. Finalize orphaned Longhorn nodes in the burst node reaper

## Context

Longhorn from [0005](0005-longhorn-storage.md) keeps its own node record for every cluster node, and its node controller removes that record once the backing Kubernetes Node is gone, but only when the record is marked unschedulable. A node that leaves the cluster while still schedulable leaves the Longhorn record stranded, which is the normal burst scale-down path. Longhorn's admission webhook then refuses to delete the record, reporting the node ready condition false because the Kubernetes Node is gone, and the node's instance manager record sits in an error state. For each stranded record `longhorn-manager` logs a warning on every reconcile. On this cluster seven decommissioned records accumulated across scale-down cycles and produced roughly 140 warning lines every five minutes across the manager pods, which tripped the log error-rate alert. The records were inert, since all volumes stayed attached and healthy and no replicas lived on the dead nodes, so the cost was log noise, a false alert, and clutter in storage state. Clearing a record by hand by marking it unschedulable let Longhorn reap it immediately, which confirmed the mechanism.

## Decision

The reaper CronJob gains a pass that finalizes stranded Longhorn nodes. It lists every Longhorn node record, skips any whose backing Kubernetes Node still exists, and for the remainder marks the record unschedulable, after which Longhorn's own controller removes it and cascades its instance manager. The reaper never deletes a Longhorn node directly: Longhorn keeps enforcing its zero-replica safety check before it removes a record and no replica eviction is forced, so a record that still holds replicas is left for Longhorn to drain and reap on its own. The existence check on the backing Kubernetes Node excludes the control plane and the home workers by construction, and it also protects a node that is only briefly unreachable, since a transient outage leaves the Kubernetes Node object in place. If the Longhorn list call fails the job logs the error and skips the storage pass without failing. The service account gains a namespaced Role in `longhorn-system` granting get, list, and patch on Longhorn nodes, and nothing else.

## Options considered

- Extend the existing reaper, chosen. It already owns burst-node cleanup and already runs on a fail-safe schedule, so the storage cleanup rides the same job with no new component and no new latency requirement.
- A Longhorn cleanup step inside the horizon scale-down. It would act sooner for operator-driven removals, but it never runs for autoscaler-driven scale-down or for a node that crashes out, both of which strand records the same way, and it would couple a provider-agnostic tool to Longhorn.
- A dedicated controller watching Node and Longhorn node objects. It reacts faster than a ten-minute poll but is far more code and operational surface for a tidy-up with no latency requirement, the same reasoning [0026](0026-orphan-node-reaper.md) recorded.

## Consequences

Stranded Longhorn nodes and their instance manager records clear within one reaper interval without operator action, the warning stream stops, and the alert that surfaced the problem stops firing on it. The reaper reads and patches Longhorn nodes, a small widening of its blast radius, bounded to one field on records whose backing Kubernetes Node is already gone, so a live or briefly unreachable node is never touched, and it degrades to a logged skip when the Longhorn API is unreachable. The poll interval bounds the lag, so a record can sit stranded for up to ten minutes before it is finalized, which is acceptable for cleanup. This pass is the only one left in the job. [0071](0071-deploy-horizon-operator-from-published-chart.md) gave Node deletion to the horizon operator and stripped the Kubernetes Node pass, renaming the CronJob to `longhorn-node-finalizer` to match what it does, and narrowing its cluster-scoped grant on core nodes to get alone. The finalize logic, the schedule, the zero-replica safety left to Longhorn, and the degrade-to-skip behaviour are all unchanged; the only difference is that the state it corrects is now produced by the horizon operator rather than by the reaper itself, which is the case the first option weighed here already anticipated.

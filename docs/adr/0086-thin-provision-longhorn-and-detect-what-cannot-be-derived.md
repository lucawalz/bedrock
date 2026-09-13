---
status: accepted
date: 2026-09-08
---

# 0086. Thin provision Longhorn, and detect what no derived expression can

## Context

No three-replica volume larger than about 8.5 GiB could be provisioned anywhere in the cluster, and
`zot/data-zot-0` had been reporting `Scheduled=False` with reason `LocalReplicaSchedulingFailure` for
over two days, while the disks were roughly a third full.

Longhorn schedules against a volume's **declared** size. A replica's full declaration is charged to a
disk's budget the moment it is placed, whatever the volume contains, and that budget is
`(storageMaximum - storageReserved) * storageOverProvisioningPercentage / 100`, so at 100 percent a
declared byte and a written byte cost the same. The estate's volumes declared 667.9 GB of replica
bytes to hold 61.2 GB of data, with a further 52.1 GB in snapshots. Measured across the three nodes:

| node | maximum | reserved | budget | scheduled | percent of budget | real used |
| --- | --- | --- | --- | --- | --- | --- |
| control-plane-1 | 250.4 GB | 50.1 GB | 200.3 GB | 178.2 GB | 89.0 | 42.1 |
| worker-1 | 250.4 GB | 50.1 GB | 200.3 GB | 191.1 GB | 95.4 | 26.9 |
| worker-2 | 502.4 GB | 100.5 GB | 401.9 GB | 298.5 GB | 74.3 | 28.3 |

With hard replica anti-affinity a three-replica volume needs room on all three nodes, so worker-1
bound the estate and its 9.2 GB of remaining budget is the 8.57 GiB ceiling exactly. Provisioning had
run out at 17 percent real utilisation while every disk was schedulable, healthy and two thirds
empty. The reported symptom was not that ceiling: `zot/data-zot-0` was attached and healthy, and
`longhorn-disposable` sets `dataLocality: best-effort`, so Longhorn had created a second replica
record to place a copy local to the pod on worker-1, where the 85.9 GB it declared did not fit. The
volume was never at risk, and that unsatisfiable placement preference was the only thing in the
estate that said anything at all.

## Decision

**Schedule against a thin-provisioned budget.** `storageOverProvisioningPercentage` moves from 100 to
200, raising the ceiling on a new three-replica volume to roughly 128 GiB.
`storageMinimalAvailablePercentage` stays at 25 and becomes the guard that matters, because unlike
the over-provisioning budget it is measured against **real** free bytes, so scheduling stops when a
disk genuinely fills regardless of what has been promised to volumes that will never use it. Real
usage was well inside that floor on every node.

**Reconcile the per-disk reserve up to the 30 percent the chart already declares**, rather than
lowering the chart to the 20 percent every live disk had been set to by hand, so that a recreated
disk record comes up at the budget in force; that drift already bit once, in
[0083](0083-rename-control-plane-node-to-control-plane-1.md). The order is not optional: at 100
percent over-provisioning a 30 percent reserve puts two nodes over their budgets, so the setting has
to reach the live cluster before the reserve is touched.

**Right-size zot rather than treating it as an alternative to the setting.** The two were framed as
competing levers and are not: once over-provisioning rises the pending local replica becomes
schedulable immediately and parks a permanent 85.9 GB claim on the binding node, spending most of the
headroom the change just created. Zot is a pull-through cache holding 2.5 GB under a retention policy
that has bounded it correctly since [0067](0067-pull-through-registry-cache.md)'s second update, so
20Gi is eight times its settled working set, reached by the recreate that record already calls the
right remedy for a volume disposable by design.

**Divide the headroom alerts by the budget that now exists.** Both expressions divided by capacity
minus reservation and omitted the over-provisioning factor, so at 200 percent they would have fired
at half a budget nowhere near exhausted. This is the third instance of the defect
[0085](0085-guardrails-silently-failed-when-derived-basis-moved.md) names, and the first where the
change and the guardrail it breaks had to land together. One recording rule,
`longhorn:node_replica_scheduling:budget_used_percent`, now holds the whole basis.

**Detect the conditions no expression can be derived for.** Longhorn exports no metric for a volume's
`Scheduled` condition, and both its per-volume robustness and its per-disk schedulability read
healthy throughout, because the disks were schedulable in general and only one replica did not fit.
`longhorn.rules` also alerted only on degraded robustness, so a faulted volume raised nothing, which
[0082](0082-gitops-guardrail-boundary.md) had assumed was covered. `LonghornVolumeUnschedulable`
reads the `Scheduled` condition through the kube-state-metrics `customResourceState` config that
already exposes Flux HelmRelease conditions, while `LonghornVolumeFaulted` and
`LonghornDiskUnschedulable` read Longhorn's own verdicts and so re-derive nothing.

## Options considered

- Thin provision, and pair the derived alerts with ones that read Longhorn's own verdict, chosen. It
  raises the ceiling without promising a disk it cannot deliver, and leaves a signal that survives
  the settings changing again.
- Right-size the declarations instead. Rejected. Longhorn cannot shrink, so each is a recreate with
  data migration, and it fights a tool where a declaration is a ceiling to grow into, trading a
  one-time provisioning problem for a permanent expansion treadmill.
- Drop the per-disk reserve to zero instead of raising over-provisioning. Rejected. It reaches a 55
  GiB ceiling in one line, but the reserve is the only thing standing between replica scheduling and
  the operating system, the nix store and containerd's image store on the same disk.
- Put the over-provisioning factor in both alert expressions rather than in a recording rule.
  Rejected. Two copies of a number duplicating a HelmRelease value is the defect 0085 records,
  doubled; one copy is still a duplicate, but it is one a promtool case can pin.
- Alert on the `Scheduled` condition only and drop the headroom alerts as unreliable. Rejected. The
  condition is reactive and fires once a replica has already failed to place, where the headroom
  alerts are predictive, and 0085 exists because that prediction was wanted and silently absent.

## Consequences

Longhorn now promises more bytes than the disks hold. What bounds the estate is no longer arithmetic
on declarations but real free space, measured by `storageMinimalAvailablePercentage` for scheduling
and by `NodeFilesystemAlmostOutOfSpace`, `PersistentVolumeFillingUp` and
`PersistentVolumeAlmostFull` for what is written: a provisioning ceiling that tracked nothing real
exchanged for a fill ceiling that does.

The over-provisioning factor remains a literal in PromQL duplicating a value in a HelmRelease,
because Longhorn exports no metric for the setting. Single-sourcing it and pinning it with a promtool
case verified to go red when it is dropped is a mitigation rather than a fix; what makes it
acceptable is `LonghornDiskUnschedulable` staying correct when the derived expression no longer is.
The pattern worth carrying forward from this record and from 0085 is that a guardrail derived from a
value that can move should be paired with one that reads the system's own answer.

The gap between declaration and contents is now measured rather than found by failing.
`LonghornVolumeOverDeclared` needs a declaration more than ten times the contents **and** a gap
costing over 20 GB of scheduling budget once multiplied by the replica count, because either guard
alone is wrong: a ratio fires on every freshly created volume, where actual size is near zero while
nothing is wasted, and an absolute gap fires on a large volume in genuine use. It does not demand
action, since every correction is a claim recreated with its data migrated.

One thing is left open. `longhorn-disposable` is `volumeBindingMode: Immediate`, so a replica is
placed before its pod is scheduled, and any single-replica volume on that class with
`dataLocality: best-effort` chronically wants a second full declared copy on whichever node its pod
lands on. At 20Gi zot's now fits everywhere, so the symptom is gone and the mechanism is not, and
`volumeBindingMode: WaitForFirstConsumer` remains unverified against Longhorn's CSI driver.

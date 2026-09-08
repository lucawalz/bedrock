---
status: accepted
date: 2026-09-08
---

# 0086. Thin provision Longhorn, and detect what no derived expression can

## Context

No three-replica volume larger than about 8.5 GiB could be provisioned anywhere in the cluster, and
`zot/data-zot-0` had reported `Scheduled=False` with reason `LocalReplicaSchedulingFailure` and
message `insufficient storage` since 2026-09-06T18:57:31Z. The disks were roughly a third full.

Longhorn schedules against a volume's **declared** size. A replica's full declaration is charged to a
disk's budget the moment it is placed, whatever the volume actually contains, and the budget is
`(storageMaximum - storageReserved) * storageOverProvisioningPercentage / 100`. With
`storage-over-provisioning-percentage` at 100 that budget is the physical disk minus the reserve,
which means a declared byte and a written byte cost exactly the same.

Nineteen volumes declared 667.9 GB of replica bytes to hold 61.2 GB of data, an eleven times
over-declaration, with a further 52.1 GB in snapshots. Measured across the three nodes:

| node | maximum | reserved | budget | scheduled | percent of budget | real used |
| --- | --- | --- | --- | --- | --- | --- |
| control-plane-1 | 250.4 GB | 50.1 GB | 200.3 GB | 178.2 GB | 89.0 | 42.1 |
| worker-1 | 250.4 GB | 50.1 GB | 200.3 GB | 191.1 GB | 95.4 | 26.9 |
| worker-2 | 502.4 GB | 100.5 GB | 401.9 GB | 298.5 GB | 74.3 | 28.3 |

With hard replica anti-affinity a three-replica volume needs room on all three nodes, so worker-1
bound the estate: its 9.2 GB of remaining budget is the 8.57 GiB ceiling exactly. The estate had run
out of provisioning at 17 percent real utilisation, and every disk was schedulable, healthy, and two
thirds empty while it happened.

**The reported symptom was not the ceiling itself.** `zot/data-zot-0` was `attached` and `healthy`
throughout, serving normally from its single replica on worker-2. `longhorn-disposable` sets
`dataLocality: best-effort`, so Longhorn had created a second replica record with an empty `nodeID`
to place a copy local to the `zot-0` pod on worker-1, and that 85.9 GB local replica did not fit in
worker-1's 9.2 GB. The volume was never at risk; the condition was Longhorn reporting that it could
not satisfy a placement preference. That distinction matters because it is the reason the incident
was legible at all: nothing else in the estate said anything.

## Decision

**Schedule against a thin-provisioned budget.** `storageOverProvisioningPercentage` in
`kubernetes/infrastructure/controllers/onprem/longhorn/helmrelease.yaml` moves from 100 to 200.
`storageMinimalAvailablePercentage` stays at 25 and becomes the guard that matters: unlike the
over-provisioning budget it is measured against **real** free bytes, so scheduling stops when a disk
genuinely fills regardless of what has been promised to volumes that will never use it. Real usage
was 42.1, 26.9 and 28.3 percent against that 75 percent floor, and `NodeFilesystemAlmostOutOfSpace`
already covers exhaustion of the filesystem holding `/var/lib/longhorn`. The ceiling on a new
three-replica volume rises from 8.57 GiB to roughly 128 GiB.

**Reconcile the per-disk reserve up to what the chart already declares.** The chart declared 30
percent while every live disk sat at exactly 20, set by hand, so a recreated disk record came up with
a different budget than the one in force, which [0083](0083-rename-control-plane-node-to-control-plane-1.md)
already recorded happening once. Raising the live value to 30 percent rather than lowering the chart
to 20 makes recreation idempotent and matches what the disks hold: non-Longhorn usage on
control-plane-1 is already 73 GB, 29 percent of that disk. The order is not optional. At 100 percent
a 30 percent reserve puts control-plane-1 and worker-1 over their budgets, so the setting has to
reach the live cluster before the reserve is touched.

**Right-size zot rather than treating it as an alternative to the setting.** These were framed as
competing levers and they are not. Once over-provisioning rises the pending local replica becomes
schedulable immediately, and Longhorn parks a permanent 85.9 GB claim on worker-1, the binding node,
spending most of the headroom the change just created. Zot is a pull-through cache holding 2.5 GB
under a retention policy that has been bounding it correctly since
[0067](0067-pull-through-registry-cache.md)'s second update; 20Gi is eight times its settled working
set. Longhorn expands but does not shrink, so this is a recreate, which the cache's own record
already calls the correct remedy for a volume disposable by design.

**Divide the headroom alerts by the budget that now exists.** Both expressions divided by
`capacity - reservation` and omitted the over-provisioning factor. At 200 percent that denominator is
half the real budget, so both would have fired at 50 percent of a budget nowhere near exhausted, and
both descriptions asserted that Longhorn refuses to schedule once the figure reaches 100 percent,
which stops being true. This is the third instance of the defect
[0085](0085-guardrails-silently-failed-when-derived-basis-moved.md) names, and the first where the
change that breaks the guardrail and the guardrail itself had to land together. A single recording
rule, `longhorn:node_replica_scheduling:budget_used_percent`, now holds the whole basis so the factor
appears exactly once, written as `* 200 / 100` so the literal reads as the value it duplicates.

**Detect the conditions no expression can be derived for.** Longhorn exports no metric for a volume's
`Scheduled` condition. `longhorn_volume_robustness` reported zot healthy, which it was, and
`longhorn_disk_status{condition="schedulable"}` was 1 on every disk, because the disks were
schedulable in general and only this one replica did not fit. Nothing in Prometheus could see the
condition and it went unnoticed for over two days. Separately, `longhorn.rules` alerted only on
`longhorn_volume_robustness == 2`, so a faulted volume raised nothing at all, which
[0082](0082-gitops-guardrail-boundary.md) had assumed was covered when it recorded the single-replica
trade-off. Three alerts close both gaps. `LonghornVolumeUnschedulable` reads the `Scheduled` condition
through the kube-state-metrics `customResourceState` config that already exposes Flux HelmRelease
conditions the same way. `LonghornVolumeFaulted` fires on robustness 3. `LonghornDiskUnschedulable`
fires on Longhorn's own per-disk verdict. The last two re-derive nothing, so they hold whatever the
over-provisioning and reservation settings become.

## Options considered

- **Right-size the declarations instead of over-provisioning, rejected.** Bringing 668 GB of
  declarations down to fit a 802 GB budget at 100 percent means shrinking most of eighteen volumes,
  and Longhorn cannot shrink: each one is a recreate with data migration. It also fights the grain of
  the tool. A declaration is meant to be a ceiling a volume may grow into, and forcing them tight
  trades a one-time provisioning problem for a permanent expansion treadmill, where every growth is a
  resize plus a filesystem grow rather than nothing at all. Zot is right-sized here not as a step
  toward that policy but because 80Gi for 2.5 GB is a misdeclaration by any standard, and because
  leaving it would have consumed the headroom this change creates.
- **Drop the per-disk reserve to zero rather than raise over-provisioning, rejected.** It reaches a
  55 GiB ceiling with a one-line change and no thin provisioning at all. It also lets Longhorn
  promise every byte of a disk that holds the operating system, the nix store and containerd's image
  store, and control-plane-1's non-Longhorn usage alone is 73 GB. The reserve is the only thing
  standing between replica scheduling and the rest of the machine.
- **Put the over-provisioning factor in both alert expressions rather than in a recording rule,
  rejected.** Two copies of a number that duplicates a HelmRelease value is the shape of the defect
  0085 records, doubled. One copy is still a duplicate, but it is a duplicate a promtool case can pin.
- **Alert on the `Scheduled` condition only, and drop the headroom alerts as unreliable, rejected.**
  The condition-reading alert is reactive: it fires once a volume has already failed to place a
  replica. The headroom alerts are predictive, and 0085 exists precisely because that prediction was
  wanted and silently absent. Both are kept, doing different jobs.

## Consequences

Longhorn will now promise more bytes than the disks hold, and nothing stops a volume writing into
space that was promised twice. What bounds the estate is no longer arithmetic on declarations but
real free space, measured by `storageMinimalAvailablePercentage` for scheduling and by
`NodeFilesystemAlmostOutOfSpace`, `PersistentVolumeFillingUp` and `PersistentVolumeAlmostFull` for
what is actually written. That is the trade this record accepts: a provisioning ceiling that tracked
nothing real is exchanged for a fill ceiling that does, and the guardrails move with it.

The over-provisioning factor remains a literal in PromQL that duplicates a value in a HelmRelease,
because Longhorn exports no metric for the setting and Prometheus has no way to read one. It is
single-sourced in one recording rule and pinned by a promtool case that fails if the factor is
dropped, and dropping it was verified to turn four cases red. That is a mitigation and not a fix. The
reason it is acceptable is `LonghornDiskUnschedulable`, which reads Longhorn's own verdict and stays
correct when the derived expression no longer is. The pattern worth carrying forward from this and
from 0085 is that a guardrail derived from a value that can move should be paired with one that reads
the system's own answer.

Two things are left open. `longhorn-disposable` is `volumeBindingMode: Immediate`, so a replica is
placed before its pod is scheduled, and any single-replica volume on that class with
`dataLocality: best-effort` will chronically want a second full declared copy on whichever node its
pod lands on. At 20Gi with the new budgets zot's fits everywhere, so the symptom is gone, but the
mechanism is not, and it will return for any large enough disposable volume.
`volumeBindingMode: WaitForFirstConsumer` is the likely answer and was not verified against
Longhorn's CSI driver, so it is not in this change. Separately, nothing detects a volume whose
declaration drifts far from its contents; zot was found because it failed, not because anything
measured the gap, and three volumes still declare 21.5 GB to hold under a gigabyte each.

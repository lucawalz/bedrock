---
status: accepted
date: 2026-09-06
---

# 0082. Establish the GitOps guardrail boundary and its accepted trade-offs

## Context

A production-readiness pass touched nearly every controller in the estate: chart pinning, drift
detection, snapshot coverage, node addressing, admission recovery, and the alerting that watches all
of it. Each of those areas raises the same question, whether a thing belongs in git or whether an
imperative step is honest about what the estate needs, and answering it component by component would
have produced inconsistent answers for one underlying shape of problem. The work adopted one rule up
front instead: GitOps the guardrails always, the contents only when it helps. Namespaces, pod-security
labels, NetworkPolicies, ServiceAccount patches and snapshot-group membership are always declared,
and so is a disruption budget wherever a workload has more than one replica to protect, because they
are the boundary that keeps a workload from doing harm regardless of what runs inside it. What runs inside that boundary may be imperative when that is the honest
description of the estate, and when it is, the step is written down in the disaster-recovery runbook
or the admission break-glass runbook rather than represented as something git controls.

## Decision

**media-encode.** The namespace is adopted with its guardrails fully declared: pod-security labels at
`baseline`, a default-ServiceAccount patch, and the base network-policy component. Nothing routes to
it and its workloads take no outbound traffic, so the traefik-ingress and internet-egress components
are left off. The three workloads are hand-managed outside Flux, because they are stock unprivileged
nginx images with no environment, command, probes or volumes: they satisfy the guardrails the
namespace declares, but they are scaffolding for a pipeline that has not been built, and the namespace
is recorded as such rather than as a functioning workload.

**Snapshot-group membership is declared per volume.** Rather than making Longhorn snapshot membership
an implicit default, every PersistentVolumeClaim and `volumeClaimTemplate` git can see states its
membership directly, including Grafana's through the chart's `persistence.extraPvcLabels` key, while
the dashboards stay provisioned through chart values as before. Five volumes cannot be reached this
way, because their charts expose no field that would let a label land on the claim they create; they
are named in the disaster-recovery runbook, because they are the boundary of what the guardrail can
declare rather than an oversight in applying it.

**Single-replica volumes on `longhorn-disposable`.** Longhorn's Degraded robustness state means some
but not all replicas are healthy, which cannot exist when a volume has one, so
`LonghornVolumeDegraded` has no state to catch and such a volume goes straight from healthy to
faulted. When this was written nothing alerted on faulted either;
[0086](0086-thin-provision-longhorn-and-detect-what-cannot-be-derived.md) added
`LonghornVolumeFaulted`, leaving a late signal rather than no signal.

**Floating chart versions are pinned.** Twenty HelmReleases carried a floating version range instead
of the exact version deployed. Such a range resolves inside the cluster at reconcile time against
whatever the chart repository currently serves, so nothing outside the cluster ever sees the change
and no process gets to review it. All twenty are pinned to the version measured live. The sharper
finding is that five were also on Renovate's hold list for critical infrastructure, the rule requiring
a human to approve their updates: a floating range never produces the pull request that rule is
written to hold, so for exactly the charts the estate most wanted a decision on, it had nothing to
act on.

**`remediateLastFailure` on the stateful releases.** `cloudnative-pg`, `longhorn`, `minio` and
`horizon` already carried `remediateLastFailure: false`, set deliberately by an earlier commit that
stopped Flux from rolling back a failed upgrade on stateful infrastructure mid-migration. Only
`authentik` was missing it, and it runs database migrations on start, which is exactly that hazard, so
it now carries the same `false` and the other four are untouched. The trade-off is real: a failed
upgrade on any of the five stalls with the old release still deployed and serving, and nothing beyond
Flux's own retries moves it forward. The compensating control is a critical `HelmReleaseStalled` alert,
which fires when a HelmRelease reports `Ready=False` for more than five minutes, so the stall reaches
a human promptly instead of waiting inside a twelve-hour digest.

**Drift detection at `warn`, not `enabled`.** Every HelmRelease sets `driftDetection.mode: warn`. The
failure this closes is a release that reports success while the live cluster no longer matches what
git declares, which previously produced no event at all. `mode: enabled` was rejected because it does
not just report drift, it corrects it by reapplying the release, which risks fighting any field a
mutating admission controller or another controller owns and turns a reporting gap into a live
reconcile loop. The alert built to surface the warning has since been removed: it read a `Drifted`
status condition, and helm-controller reports drift as an event and writes no such condition, so it
could never fire and its kube-state-metrics block and RBAC entry went with it. The mode stays, because
the event is still the record that a release drifted, but this trade-off should be read as uncovered
by an alert, and covering it needs an event exporter the estate does not run.

**metrics-server adopted from the k3s addon.** `--disable=metrics-server` now sits beside
`--disable=coredns` on the pattern CoreDNS established: a k3s addon is a bounded, unreconciled binary
the cluster starts with no upgrade path of its own, and every other controller in the estate is a
Flux-managed chart at a pinned version. The move puts its image on `registry.k8s.io`, already an
explicit containerd mirror and a sync target for the pull-through cache in
[0067](0067-pull-through-registry-cache.md), so it adds no external dependency. The Kustomization
shipped suspended, because Helm 3 refuses to adopt objects it does not own and the addon still owned
all four, while disabling the addon is a node rebuild Flux can neither depend on nor wait for. That
rebuild happened under [0083](0083-rename-control-plane-node-to-control-plane-1.md), and `suspend` was
then removed from the manifest so the resumed state is the declared one.

**Longhorn `storageReserved` stays imperative.** The chart's reserve percentage only takes effect when
Longhorn first creates a disk record, and the `nodes.longhorn.io` object carrying the live value is
continuously rewritten by the Longhorn controller, so no manifest can hold that field without fighting
the controller for it. The reserve is set with a direct patch recorded in the disaster-recovery
runbook. The premise that made this urgent did not hold: the containerd image store is not unbounded,
because kubelet's image garbage collector already runs to thresholds set in `modules/k3s/estate.nix`,
so the reserve is a genuine allocation between Longhorn and the rest of the disk rather than a second
mechanism papering over an unbounded one. The patch is no longer owed after every disk recreation
either, because [0086](0086-thin-provision-longhorn-and-detect-what-cannot-be-derived.md) raised the
live reserve to the percentage the chart declares.

Seven further findings are recorded rather than closed, because each is a fact about the estate that
no configuration in this repository can change:

- The Pi is VLAN 20's only gateway and the only Layer 3 path from the operator's LAN, so static node
  addressing, a second `--tls-san` per node and a sequential CoreDNS forward list buy independence
  from kea, from the subnet router and from AdGuard respectively, and never from the Pi itself.
- The dead-man's switch runs on the Pi and cannot observe the death of the device it runs on.
- The cluster runs one control-plane node, at the cost
  [0053](0053-ha-critical-path-survives-node-loss.md) proves; three control planes and three workers
  is the hardware goal, unbuilt and unbought.
- `rancher-webhook`'s Deployment renders `resources` as an empty object owned by the `helm` field
  manager, so a patch setting requests and limits is reverted on every reconcile, which the admission
  break-glass runbook carries alongside the patch.
- `secretsDir = "${self}/secrets"` ties every host's closure hash to the content-addressed path of the
  whole flake source, so an unexplained closure change should be checked against this before it is
  read as configuration drift.
- Dozens of literal VLAN 20 addresses sit in `kubernetes/` with nothing analogous to
  `lib/inventory.nix` behind them, and the inventory models VLAN 20 alone.
- Kyverno's `policyExceptions.namespace` pin reconciles under `cluster-security` while the exceptions
  live under `cluster-policies`, and `cluster-apps` waits on neither, so a rebuild reopens a window in
  which restarting pods are admitted with no exceptions. The mitigation is procedural: suspend the
  application tier until the exceptions are present, or split the pin into a second push.

## Options considered

- State one governing rule and record every decision under it, chosen. A component-by-component answer
  would have given a different boundary for `rancher-webhook`'s resources than for its replica count,
  even though both are chart-rendered fields outside this repository's control, purely because they
  surfaced in different tasks. One rule is auditable in a way a pile of exceptions is not.
- GitOps everything, including the fields Helm's own field manager owns and the storage reserve
  Longhorn only accepts on disk creation. Rejected. Both would mean fighting a controller for
  ownership of a field on every reconcile, which is worse than an honest recorded imperative step.
- Leave floating chart ranges and unset drift detection, accepting that some silent drift is the cost
  of a small cluster. Rejected, because chart drift and hold-list evasion were measured as live: five
  held charts were already floating past the point the hold rule exists to stop.
- Reverse the earlier `remediateLastFailure: false` decision back to automatic rollback, as the
  originating spec proposed. Rejected on the same reasoning the earlier commit recorded: an automatic
  rollback mid-upgrade on stateful infrastructure is a worse resting state than a visible stall.

## Consequences

The estate has a written boundary for where GitOps stops, instead of an implicit one rediscovered
incident by incident, and every imperative step this record accepts is named in one of the two
runbooks so a rebuild does not depend on remembering it.

The risks listed above remain exactly as exposed as they were before the pass; what changed is that
each is written down with its actual shape rather than assumed away. The volumes on
`longhorn-disposable` still jump straight to faulted with no earlier warning, and the five volumes
with no claim label field still fall back to Longhorn's implicit default snapshot group.

`HelmReleaseStalled` is the one control this record depends on that works, and if it stops firing the
five stateful releases that no longer roll back automatically revert to the uncovered failure mode this
pass set out to close. The drift half has no such control, for the reason recorded above.

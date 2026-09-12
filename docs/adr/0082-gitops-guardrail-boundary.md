---
status: accepted
date: 2026-09-06
---

# 0082. Establish the GitOps guardrail boundary and its accepted trade-offs

## Context

A production-readiness pass touched nearly every controller in the estate: chart pinning, drift
detection, snapshot coverage, node addressing, admission recovery, and the alerting that watches
all of it. Taken one at a time, each of those areas raises the same question: does this belong in
git, or is an imperative step honest about what the estate actually needs. Answering it
component by component would have produced inconsistent answers for the same underlying shape of
problem, so the work adopted one rule up front and applied it throughout.

The rule: GitOps the guardrails always, the contents only when it helps. Namespaces, pod-security
labels, NetworkPolicies, ServiceAccount patches, PodDisruptionBudgets, and snapshot-group
membership are always declared, because they are the boundary that keeps a workload from doing
harm regardless of what runs inside it. What runs inside that boundary may be imperative when
that is the honest description of the estate today, and when it is, the imperative step is
written down in the disaster-recovery runbook or the admission break-glass runbook rather than
represented as something git controls.

This record states that rule and every decision made under it during the pass, including several
places where investigation reversed what was originally proposed.

## Decision

**media-encode.** The namespace is adopted with its guardrails fully declared: pod-security
labels at `baseline`, a default-ServiceAccount patch, and the base network-policy component.
No `IngressRoute` targets it and its workloads take no outbound traffic, so the wider
traefik-ingress and internet-egress components are deliberately left off. The three workloads
themselves, `shot-index`, `thumbnailer` and `transcoder`, are hand-managed outside Flux, because
they are stock `nginxinc/nginx-unprivileged:1.27-alpine` images with no environment, command,
probes, or volumes of their own. They satisfy the guardrails the namespace declares, but they are
scaffolding for a pipeline that has not been built yet rather than a working one, and the
namespace's status is recorded as such rather than presented as a functioning workload.

**Grafana dashboards and the volumes behind them.** Dashboards themselves stay in the interface,
provisioned through the chart's own values, which is the declarative path that already existed.
What changed is the data volume: rather than trying to make Longhorn snapshot membership an
implicit default, every PersistentVolumeClaim and `volumeClaimTemplate` git can see now states its
snapshot-group membership directly, including Grafana's, through the chart's own
`persistence.extraPvcLabels` key. Five volumes cannot be reached this way at all, because their
charts expose no field that would let a label land on the PVC they create: `storage-tempo-0`,
`minio-minio`, `pgadmin-pgadmin4`, `ollama`, and `data-zot-0`. They are named here rather than left
to be rediscovered, because they are the boundary of what the guardrail can declare, not an
oversight in applying it.

**Single-replica volumes on `longhorn-disposable`.** `kiwix-library`, `ollama`, and `data-zot-0`
all sit on the `longhorn-disposable` storage class, which sets `numberOfReplicas: "1"`. Longhorn's
Degraded robustness state means some but not all of a volume's replicas are healthy, which cannot
exist when a volume only has one. The `LonghornVolumeDegraded` alert, which fires on
`longhorn_volume_robustness == 2`, therefore has no state to catch for these three volumes: losing
their one replica takes them straight from healthy to faulted, and the first signal anyone gets is
the faulted alert, not an earlier warning.

The faulted alert this paragraph relies on did not exist when this was written. `longhorn.rules`
carried nothing on `longhorn_volume_robustness == 3`, so the three volumes named here raised nothing
at all on total loss, rather than raising a late signal instead of an early one.
`LonghornVolumeFaulted` was added in [0086](0086-thin-provision-longhorn-and-detect-what-cannot-be-derived.md)
and the paragraph now holds as written.

**Floating chart versions.** Twenty HelmReleases carried a floating version range, such as `"5.x"`,
instead of the exact version already deployed. A floating range resolves inside the cluster at
reconcile time against whatever the chart repository currently serves, so nothing outside the
cluster ever sees the change and no process gets a chance to review it before it runs. All twenty
are now pinned to the version measured live at the time of pinning. The sharper finding is that
five of those twenty, `cert-manager`, `traefik`, `metallb`, `kube-prometheus-stack`, and
`paperless-ngx`, were also named on Renovate's own hold list for critical infrastructure, the rule
that requires a human to approve their minor and patch updates. A floating range never produces
the pull request that rule is written to hold, so for exactly the charts the estate most wanted a
human decision on, the hold rule had nothing to act on. Pinning restores the hold rule's effect for
those five along with fixing the same silent-drift exposure for the other fifteen.

**`remediateLastFailure` on the stateful releases.** `cloudnative-pg`, `longhorn`, and `minio`
already carried `remediateLastFailure: false`, and `horizon` did too; all four were set that way
deliberately by an earlier commit that stopped Flux from rolling back a failed upgrade on stateful
infrastructure mid-migration or mid-reshard. Only `authentik` was missing the key, and it runs
database migrations on start, which is exactly the hazard that earlier decision addressed for the
other four. `authentik` now carries the same `false`, and the other four are left untouched. The
trade-off this keeps is a real one: a failed upgrade on any of these five now stalls with the old
release still deployed and serving, rather than rolling back automatically, and nothing beyond
Flux's own retries moves it forward on its own. The compensating control is a new critical
`HelmReleaseStalled` alert, which fires when a HelmRelease reports `Ready=False` for more than five
minutes, so the stall reaches a human promptly instead of waiting inside the twelve-hour warning
digest that Flux's own reconciliation-failure alert would otherwise leave it in.

**Drift detection at `warn`, not `enabled`.** Every HelmRelease in the cluster now sets
`driftDetection.mode: warn`. The failure this closes is a release that reports success while the
live cluster no longer matches what git declares, which previously produced no event and no alert
at all. `mode: enabled` was rejected because it does not just report drift, it corrects it by
reapplying the release, which risks fighting any field a mutating admission controller or another
controller owns, turning a reporting gap into a live reconcile loop. `warn` reports the same
condition without acting on it. Making the signal usable needed one more piece: flux-operator's own
`flux_resource_info` metric reflects only a HelmRelease's `Ready` condition and discards the
`Drifted` condition entirely, so a new kube-state-metrics `CustomResourceStateMetrics` block was
added to expose `kube_helmrelease_status_condition` directly from the HelmRelease's own status, and
a `HelmReleaseDriftDetected` alert now reads it.

**metrics-server adopted from the k3s addon.** `--disable=metrics-server` now sits beside
`--disable=coredns` on the same pattern CoreDNS already established: a k3s addon is a bounded,
unreconciled binary the cluster starts with no upgrade path of its own, and every other controller
in the estate is a Flux-managed chart with a pinned version. metrics-server is now the same, at
chart `3.14.0`, with the CriticalAddonsOnly and control-plane tolerations carried over from the
live addon so it still schedules everywhere it needs to. This moves its image source from the
Rancher mirror the k3s addon pulls to `registry.k8s.io`, which is already an explicit containerd
mirror and an on-demand sync target for the pull-through cache described in
[0067](0067-pull-through-registry-cache.md), so the move adds no new external dependency.

The `cluster-metrics-server` Kustomization ships with `suspend: true`. The k3s addon still owns
`ServiceAccount/metrics-server`, `Deployment/metrics-server`, `Service/metrics-server` and
`APIService/v1beta1.metrics.k8s.io` through wrangler's `objectset.rio.cattle.io` annotations until
master is rebuilt with the disable flag above, and Helm 3 refuses to adopt objects it does not
already own. A reconcile against a cluster still running the addon exhausts the chart's install
retries and leaves the Kustomization stalled. Since disabling the addon is a node rebuild that Flux
cannot depend on or wait for, the Kustomization stays suspended until an operator rebuilds master and
resumes it by hand, recorded in the disaster-recovery runbook.

**Longhorn `storageReserved` stays imperative.** The chart's
`storageReservedPercentageForDefaultDisk` value only takes effect when Longhorn first creates a
disk record; changing it does nothing to a disk that already exists, and the `nodes.longhorn.io`
object carrying the live value is continuously owned and rewritten by the Longhorn controller. No
manifest can hold that field without fighting the controller for it, so the reserve on each worker
is set with a direct patch, recorded in the disaster-recovery runbook, and reapplied by hand
whenever a disk record is recreated. The premise that made this urgent was checked and did not
hold: the containerd image store is not unbounded. Kubelet's own image garbage collector already
runs at a 70 percent high threshold and a 55 percent low threshold, set in `modules/k3s/estate.nix`,
so the disk was already bounded before this pass and the imperative reserve is a genuine
allocation between Longhorn and the rest of the disk rather than a second mechanism papering over
an unbounded one.

The patch stays imperative, but it is no longer owed after every disk recreation. The live reserve
was 20 percent while the chart declared 30, so a recreated record came up at a different budget than
the one in use. [0086](0086-thin-provision-longhorn-and-detect-what-cannot-be-derived.md) raised the
live value to the chart's 30 percent, which makes recreation idempotent: the reserve a new disk
record is born with is now the reserve that was already in force. The runbook commands also named
`default-disk` on all three nodes, which is wrong for control-plane-1 since the rename in
[0083](0083-rename-control-plane-node-to-control-plane-1.md) gave its recreated record a suffixed
name, and a merge patch naming a key that does not exist adds a second disk entry rather than
failing.

**The Pi's role, stated precisely.** Three changes were made in the name of independence from the
Pi, and none of them buys independence from the Pi itself: the Pi is VLAN 20's only gateway and the
only Layer 3 path between the operator's LAN and the cluster, and total Pi loss is not mitigable
from this repository under any configuration. What each change buys is independence from one of the
Pi's own services, each of which can fail without the Pi itself failing:

| Change | The failure it actually covers |
| --- | --- |
| Static addressing on the three cluster nodes | kea down for longer than the 43200 second DHCP lease |
| A second `--tls-san` naming each node's tailnet address | the Pi's `tailscaled` subnet router wedges while routing still works |
| A sequential CoreDNS forward list through AdGuard first | AdGuard down while routing still works |

**The deadman cannot see its own host die.** The estate's dead-man's switch runs on the Pi and
receives a heartbeat from Alertmanager's `Watchdog` route over the VLAN 20 firewall. It is well
placed to notice the cluster going silent, but a dead-man's switch cannot observe the death of the
device it runs on: a total Pi failure stops the switch as certainly as it stops everything else the
Pi does, and shows nothing on the panel because the panel is also on the Pi.

**A single-server control plane, accepted rather than mitigated.** The cluster still runs one
control-plane node. [0053](0053-ha-critical-path-survives-node-loss.md) already proved what that
costs: losing master takes down every database, because CloudNativePG's instance manager refuses
to start Postgres without reading the Cluster resource from the API server first, and it takes down
external access, because MetalLB's speaker needs the API server to keep announcing the load
balancer address. Nothing in this pass changes that risk; it remains recorded rather than reduced.
The hardware goal that would close it is three control-plane nodes and three workers, unbuilt and
unbought.

**`rancher-webhook` sits outside GitOps reach entirely.** Its Deployment is owned by Rancher's own
systemcharts controller, which renders `resources` as an empty object even though the chart carries
no `resources` key of its own, and that empty rendering is owned by the `helm` field manager. A
patch that sets requests and limits on that field is reverted on every Helm reconcile, whether or
not an upgrade happens, which is a stronger and more frequent reversal than a chart simply
resetting a value on its next version bump. The replica count and anti-affinity patched onto the
same Deployment are owned by `kubectl-patch` instead and survive reconciles, which is why they are
treated differently in the admission break-glass runbook: one patch needs reapplying constantly,
the other only after a full reinstall.

**Roughly forty hardcoded VLAN 20 addresses, re-verified as more.** A grep of `kubernetes/` for
literal `10.20.0.x` addresses returns fifty-four occurrences across eighteen manifests, higher than
the estimate this pass started from. `lib/inventory.nix` is the single source of truth for the
three node addresses inside Nix, but nothing analogous exists for the Kubernetes manifests, and the
inventory itself models VLAN 20 only; VLAN 30 and VLAN 40 are not represented anywhere in code.
This is recorded as known duplication rather than fixed, since resolving it means either templating
every NetworkPolicy and ConfigMap that carries an address or building a second inventory
consumption path for Kubernetes YAML, either of which is a larger change than this pass carries.

**The flannel alert is a proxy, not a direct observation.** `FlannelInterfaceOrphaned` fires when
the `tailscale0` interface index on a node changes while that node's boot time does not, which is
the signature [0074](0074-home-nodes-on-the-tailnet.md) describes for a `tailscaled` restart that
leaves `flannel.1` bound to an interface that no longer exists. Nothing exposes the orphaned
binding itself as a metric, so the alert has to infer it from a coincidence of two other signals
rather than observe it directly. It is a reliable proxy for the ADR 0074 failure specifically,
because a full reboot changes both signals together and is correctly excluded, but it is a proxy
and not a direct measurement of the thing it is meant to catch.

**`secretsDir` ties every host's closure to the whole repository.** `secretsDir = "${self}/secrets"`
means every host's Nix closure hash depends on the content-addressed store path of the entire
flake input, so a change anywhere in this repository, including a Kubernetes manifest that touches
no Nix file at all, can move every host's closure hash even though nothing about the host itself
changed. This predates this pass and is not introduced by it. It is recorded here so a future
investigation into an unexpected closure change checks this cause before assuming a real
configuration drift.

**A deploy-order hazard between Kyverno's exception pin and the exceptions it targets, wider than a
single restarting pod.** The Kyverno HelmRelease pins `policyExceptions.namespace: kyverno`, so it
looks only in that namespace for exceptions once this reconciles. That HelmRelease lives under the
`cluster-security` Kustomization. The nine PolicyExceptions it needs to find were moved into the
`kyverno` namespace as part of the same body of work, but they live under `cluster-policies`, which
depends on `cluster-security` and therefore reconciles after it. Between the two, Kyverno is briefly
configured to look for exceptions in a namespace that does not yet hold them, and any pod that
restarts and re-enters admission in that window is evaluated with no exceptions at all.

That window is not confined to a pod that happens to restart inside it. `cluster-apps` depends only
on `cluster-namespaces`, and `cluster-authentik` depends on `cluster-cert-manager`,
`cluster-edge-onprem` and `cluster-cnpg-db`; neither waits on `cluster-security` or
`cluster-policies`, so the whole application tier reconciles in parallel with the window rather than
after it closes. This body of work also guarantees restarts inside that window rather than leaving
them to chance: `authentik-worker` restarts for its new liveness probe, `open-webui` restarts for its
new `copyAppData.resources` block, `ntfy` restarts for its replica count and probe change, and
`paperless-ai` restarts for its new `existingClaim` together with `force: true`, and all four sit
inside one of the nine PolicyExceptions this pin depends on. The workloads the exceptions protect
also include `authentik-server` and `paperless-ngx`, which do not restart on this push but reconcile
in the same unordered window.

The mitigation is procedural rather than structural: either suspend `cluster-apps` and
`cluster-authentik` until `kubectl get policyexceptions -n kyverno` returns nine, or split
`policyExceptions.namespace: kyverno` into a second push made only after the exception move has
already landed.

## Options considered

- State one governing rule and record every decision under it, chosen. A component-by-component
  answer to "declarative or imperative" would have produced a different boundary for
  `rancher-webhook`'s resources than for its replica count, even though both are chart-rendered
  fields outside this repository's control, purely because they happened to surface in different
  tasks. One rule applied consistently is auditable in a way a pile of individually justified
  exceptions is not.
- GitOps everything, including the fields Helm's own field manager owns and the storage reserve
  Longhorn only accepts on disk creation. Rejected. Both would require fighting a controller for
  ownership of a field on every reconcile, which is worse than an honest, recorded imperative step,
  and worse than the reconcile loop `driftDetection: enabled` was rejected for creating.
- Leave floating chart ranges and unset drift detection as they were, accepting that some silent
  drift is the cost of a small cluster. Rejected, because chart drift and hold-list evasion were
  measured as live, not theoretical: five held charts were already floating past the point the hold
  rule exists to stop.
- Reverse the earlier `remediateLastFailure: false` decision back to automatic rollback, as the
  originating spec proposed. Rejected, on the same reasoning the earlier commit recorded: an
  automatic rollback mid-upgrade on `cloudnative-pg`, `longhorn`, `minio`, or `horizon` is a worse
  resting state than a stalled release that is visibly stalled.

## Consequences

The estate now has a written boundary for where GitOps stops, instead of an implicit one that
would otherwise be rediscovered incident by incident. Every imperative step this record accepts is
named in the disaster-recovery runbook or the admission break-glass runbook, so a rebuild does not
depend on remembering it.

Several risks are recorded rather than closed. Total Pi loss, single-control-plane loss, the
`rancher-webhook` resources reversion, the VLAN 20 address duplication, and the Kyverno deploy-order
window all remain exactly as exposed as they were before this pass; what changed is that each one
is now written down with its actual shape rather than assumed away. The three volumes on
`longhorn-disposable` will still jump straight to faulted with no earlier warning, and the five
volumes with no PVC label field will still fall back to Longhorn's implicit default snapshot group
if that default ever changes underneath them.

The `HelmReleaseStalled` and `HelmReleaseDriftDetected` alerts are the two controls this record
depends on to keep its accepted trade-offs from becoming silent failures. If either stops firing,
the trade-off it compensates for, respectively the five stateful releases that no longer roll back
automatically and the drift detection that no longer corrects automatically, reverts to exactly the
uncovered failure mode this pass set out to close.

## Update 2026-09-07

The precondition this record set for `cluster-metrics-server`, an operator rebuilding master with
the disable flag, was satisfied when the control-plane node was rebuilt and renamed to
`control-plane-1` under [0083](0083-rename-control-plane-node-to-control-plane-1.md). The k3s addon
no longer owns the objects the chart needs to adopt, the Kustomization has been resumed, and it
reports Ready.

## Update 2026-09-12

`HelmReleaseDriftDetected` never worked and has been removed. The premise above, that
`driftDetection.mode: warn` surfaces a `Drifted` status condition for kube-state-metrics to export,
is wrong. Flux's helm-controller reports drift as a Kubernetes event and writes nothing to
`status.conditions`; verified live, every HelmRelease in the estate carries exactly two condition
types, `Ready` and `Released`, and `kube_helmrelease_status_condition{type="Drifted"}` held no
series at any point. The alert's promtool cases passed because they supplied the `Drifted` series
themselves.

The `CustomResourceStateMetrics` block that exposed `kube_helmrelease_status_condition`, and the
`helm.toolkit.fluxcd.io` entry in the kube-state-metrics RBAC rules that fed it, are removed with
it; the alert was their only consumer. `driftDetection.mode: warn` stays, because the event it
writes is still the record that a release drifted, but this record should be read as leaving that
trade-off uncovered by an alert rather than covered by one. Turning the event into a notification
needs an event exporter, which the estate does not run.

The other control this record leans on, `HelmReleaseStalled`, reads `flux_resource_info` and is
unaffected.

---
status: accepted
date: 2026-09-08
---

# 0085. Guardrails silently failed when the value they were derived from moved

## Context

The rename recorded in [0083](0083-rename-control-plane-node-to-control-plane-1.md) exposed two
latent defects, neither in a workload and both in guardrails that were already deployed and had been
passing every health check.

**NetworkPolicies enumerated a node's pod-network gateways.** `allow-node-ingress` in
`longhorn-system` and `cattle-system`, and `allow-postgres-ingress` in `postgres`, allowlisted
host-originated traffic by enumerating each node's flannel gateway pair as `/32` blocks, because such
traffic reaches a pod from cni0 at `10.42.N.1` or flannel.1 at `10.42.N.0` and never from the node's
LAN address. Flannel allocates a podCIDR per Node object rather than per node identity, so replacing
the control-plane Node object moved it to a range none of the three allowlists carried, and ingress
from the control-plane node into all three namespaces was denied. Two things made that hard to see. A
NetworkPolicy denial in this estate presents as connection refused rather than as a timeout, so it
reads like a dead service rather than a blocked one. And the visible symptom was not a network error
at all: it was the Kyverno and Rancher admission webhooks failing closed, because the API server runs
on the control-plane node and could no longer reach webhook pods on the workers, which blocked
mutations cluster-wide and made a routing fault look like an admission fault.

**The scheduling-headroom alerts could not fire.** `LonghornSchedulingHeadroomLow` and
`LonghornSchedulingHeadroomCritical` divided scheduled bytes by raw node capacity and fired above 90
and 97 percent. Longhorn schedules replicas against capacity minus the per-disk reserve, so with the
20 percent reserve then in force scheduling stopped at 80 percent of raw capacity and neither
threshold could ever be reached. Measured while the defect was live, worker-1 sat at 95.4 percent of
what it could actually schedule and 76.3 percent of what the alert measured, and `zot/data-zot-0` had
been reporting `Scheduled=False` with reason `LocalReplicaSchedulingFailure` for roughly fifteen
hours with both alerts silent throughout.

## Decision

**Widen the NetworkPolicies to every allocatable gateway pair, not the current one.** The three
policy files now enumerate `10.42.N.0/32` and `10.42.N.1/32` for N from 0 to 7. Eight slots cover the
three nodes running today, the three-plus-three control-plane goal
[0082](0082-gitops-guardrail-boundary.md) records as unbuilt, and headroom for a Node object
re-registering onto a slot other than the one it freed, which is exactly what happened during the
rename.

**Measure Longhorn headroom against the schedulable budget, not raw capacity.** Both expressions now
divide by capacity minus the per-disk reservation, with the thresholds and hold durations unchanged
and both descriptions saying the percentage is of the schedulable budget. A promtool case was added
that would have caught the original defect, and the corrected alert went from silent to pending for
worker-1 within minutes of reconciling.

**Search for the same defect elsewhere before closing this record.** Every alert expression that
divides one metric by another was checked for a raw capacity standing in for an allocatable one. The
kubelet volume-fill rules already measure against the usable figure kubelet reports, the container
memory rules compare against the limit itself, and the blog recording rules divide by request counts
rather than by any capacity, so no other alert shared this defect's shape.

## Options considered

- Enumerate eight gateway pairs and fix the denominator, chosen. It closes both defects with the
  narrowest source list that survives a Node object being replaced.
- Widen the NetworkPolicy source to `10.42.0.0/16`. Rejected. These policies sit beside a
  `default-deny` policy in each namespace, and the point of listing only the `.0` and `.1` addresses
  is that those are the only ones host-originated traffic uses; a `/16` would let any pod in any
  namespace reach `longhorn-system`, `cattle-system` and `postgres`.
- Match the allowed source by selector instead of by address. Rejected as unavailable rather than
  undesirable: host-network traffic from the API server and kubelet carries no pod or namespace
  identity to match against, so `ipBlock` is the only expressible form.
- Leave the headroom thresholds and only correct the description's units. Rejected. The description
  was not the defect, and relabelling raw capacity as something it is not would have hidden the same
  bug under corrected prose.

## Consequences

A node's podCIDR is a property of the Node object rather than of the physical node, and replacing the
object moves it: the freed range was not reused when the rename ran. Anything here that enumerates
pod-network addresses is therefore fragile across node re-registration specifically, not merely
across a change in node count. Eight slots bound that rather than fixing it, and this record first
said nothing detects a ninth allocation in advance. That is no longer true.
`NodePodCidrOutsideAllowlist` fires when any Node holds a podCIDR outside the range the three
policies enumerate, which became possible because `kube_node_info` already carries a `pod_cidr` label
that was not checked when this record was written. Its range duplicates the one in the policies,
which is acceptable only because of the direction of the failure: if the two drift apart, the alert
fires on a node that is still working rather than staying silent on one that is not.

The estate reported itself healthy throughout both defects. Every volume was healthy, every pod was
Running or Completed and every Flux Kustomization was Ready, while the control-plane node had no
ingress into three namespaces and worker-1 sat at 95.4 percent of its schedulable storage with the
one alert built to catch it silent.

The two share a shape worth naming for whatever finds the next one: a guardrail that encodes a
derived value, a pod subnet in one case and a denominator in the other, computed once and then left
to go silently wrong when the thing it was derived from moved. Neither was untested or unreviewed.
Both were correct when written and both were invisible once they stopped being correct, because
nothing observed the relationship between the guardrail and the value it depended on, only the
guardrail's own output.

The stale apiserver certificate Subject Alternative Names remain unpruned, for the reasons
[0083](0083-rename-control-plane-node-to-control-plane-1.md) records, and the one new fact is that
k3s's `--tls-san-security` flag defaults to true, so the set cannot grow further.

## Update 2026-09-12

The closing sweep above searched one shape of the defect and then declared the class closed. It was
correct about denominators and wrong about the class. An audit of every rule against the live series
database, rather than against the rules as written, found the same failure in five further shapes,
each verified live:

| rule | shape | fix |
| --- | --- | --- |
| `BlogLatencyErrorBudgetBurn*` | a label value nothing emits: the `le="0.5"` bucket is not one Traefik configures, so the recording rule produced no series | bucket moved to 0.3, the nearest boundary emitted and a tighter objective at a measured p99 of 99 milliseconds; the companion availability rule, whose `code=~"5.."` numerator matches nothing while the blog is healthy, now records zero through `or vector(0)` |
| `KubeJobFailed`, and ten further mixin rules | a metric name nothing exports: `kube_job_failed` where kube-state-metrics exports `kube_job_status_failed`, plus kubelet certificate and etcd peer series k3s never emits | mixin rules disabled through `defaultRules.disabled`, with repo-owned replacements where the signal exists elsewhere, as `etcd_request_duration_seconds_bucket` does for `etcdGRPCRequestsSlow` |
| `NodeSystemdServiceFailed` | a correct metric pinned to a job that does not carry it: the cluster nodes run the systemd collector off, while the router exports it under the `pi-router` job | mixin rule disabled and replaced by a repo-owned rule with no job pin, so the gateway host keeps coverage and any host that gains the collector is covered without another edit |
| `HelmReleaseDriftDetected` | a condition type nothing emits: helm-controller reports drift as an event and writes no `Drifted` condition | alert, its kube-state-metrics block and its RBAC rule removed, and [0082](0082-gitops-guardrail-boundary.md) now records the trade-off it was compensating for as uncovered |
| the four `KubeStateMetrics` rules | an endpoint that exists but is not scraped: the series live on the exporter's own telemetry port, which the chart leaves off the Service unless `selfMonitor` is set | `kube-state-metrics.selfMonitor.enabled` set to true, since nothing was misnamed and only the scrape configuration was wrong |

What these share with the two defects above is not the arithmetic, it is the direction of the check.
`promtool` proves a rule parses and behaves as its unit test says, and the unit test supplies the
series, so a rule selecting a metric, a label value or a condition type that nothing in the estate
emits passes exactly as a working rule does. None of these rules was untested. Each was tested
against a world in which its premise held. An Alertmanager inhibition of the same shape was corrected
alongside them: it matched critical to warning with `equal: [namespace]`, and Alertmanager counts a
label absent on both sides as equal, so one firing namespace-less critical suppressed every
namespace-less warning. Both sides now also require `namespace =~ ".+"`.

**The gate that closes the class.** `scripts/check-alert-selectors.sh` resolves every metric selector
in every rule Prometheus has loaded, this repository's and the mixin's alike, against the live series
database. It parses each expression through Prometheus's own parser, rebuilds each selector from its
exact-match label matchers, and asks whether that whole selector matches anything. Rebuilding the
whole selector rather than checking each label separately is load-bearing, because two matchers can
each match series while their conjunction matches none; the first draft checked per label and had
exactly the defect it exists to find. Regular-expression, negative and empty-string matchers are
dropped, since all three are written to match nothing while the estate is healthy, and a selector
that is legitimately empty is recorded in `scripts/alert-selector-allowlist.txt` with its reason, so
an expected absence is a written statement rather than a silence. Run against the estate before these
changes landed, and told to look for nothing in particular, it reported every defect above bar the
availability numerator directly, and that one indirectly through the recording rule it left empty.

The gate needs cluster access, so it is an operator gate, documented in
[the alert selector audit](../alert-selector-audit.md) and deliberately absent from the workflow: a
job that cannot reach Prometheus would either fail on every pull request or be made to pass by
skipping the work, and a gate that has been made to pass is what this record is about. Its claim is
narrower than the one this record made when it first closed. It observes the relationship between a
rule and the series it depends on, which is what was missing, and not the relationship between a
threshold and what the threshold is meant to mean, so a rule comparing a metric that exists against a
number that is wrong still passes. It also observes nothing on its own schedule, and a gate nobody
runs is a gate that is not there. Scheduling it is deferred on where a failure should land: the
natural destination is an alert, and an alert about whether the alerts can fire has the same liveness
problem one layer up, which this estate solves for Prometheus itself with an external deadman on the
router rather than with another alert.

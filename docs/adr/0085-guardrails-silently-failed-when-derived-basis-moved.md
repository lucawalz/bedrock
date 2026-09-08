---
status: accepted
date: 2026-09-08
---

# 0085. Guardrails silently failed when the value they were derived from moved

## Context

The rename recorded in [0083](0083-rename-control-plane-node-to-control-plane-1.md) exposed two
latent defects, neither in a workload and both in guardrails that were already deployed and had
been passing every health check. Both are fixed and live. This record states what they were, why
the estate looked healthy while they were active, and what they have in common.

**NetworkPolicies enumerated a node's pod-network gateways.** `allow-node-ingress` in
`longhorn-system` and `cattle-system`, and `allow-postgres-ingress` in `postgres`, allowlisted
host-originated traffic by enumerating each node's flannel gateway pair as `/32` blocks:
`10.42.0.0`, `10.42.0.1`, `10.42.1.0`, `10.42.1.1`, `10.42.2.0`, `10.42.2.1`, plus the three node
LAN addresses. The files carried a correct comment explaining the mechanism: host-originated
traffic reaches a pod from cni0 at `10.42.N.1` or flannel.1 at `10.42.N.0`, never from the node's
LAN address.

Flannel allocates a podCIDR per Node object, not per node identity. [0083](0083-rename-control-plane-node-to-control-plane-1.md)'s
2026-09-07 update already recorded this for the rename itself: replacing the control-plane Node
object allocated it `10.42.3.0/24` where `master` had held `10.42.0.0/24`. Neither `10.42.3.0` nor
`10.42.3.1` was in any of the three allowlists, so ingress from the control-plane node into
`longhorn-system`, `cattle-system`, and `postgres` was denied.

Two things made this hard to see. A NetworkPolicy denial in this estate presents as connection
refused rather than as a timeout, so it reads like a dead service rather than a blocked one. And the
visible symptom was not a network error at all: it was the Kyverno and Rancher admission webhooks
failing closed, because the API server runs on the control-plane node and could no longer reach
webhook pods on the workers. That blocked Secret and Pod mutations cluster-wide and made a routing
fault look like an admission fault, the same shape of misdirection [0083](0083-rename-control-plane-node-to-control-plane-1.md)
already recorded for the missing flannel VXLAN forwarding entry during the same rename. It also
left Longhorn's CSI components unable to reach the Longhorn API, which is why they crashlooped
through the rename instead of self-recovering.

**The scheduling-headroom alerts could not fire.** `LonghornSchedulingHeadroomLow` and
`LonghornSchedulingHeadroomCritical` computed
`longhorn_node_storage_scheduled_bytes / longhorn_node_storage_capacity_bytes * 100` and fired
above 90 and 97 respectively. Longhorn schedules replicas against capacity minus the per-disk
reserve, not against raw capacity. With the estate's 20 percent reserve, scheduling stops at 80
percent of raw capacity, so a 90 percent threshold sits past the point where scheduling has already
failed, and a 97 percent threshold further still. Neither alert could ever fire.

Measured while the defect was live: worker-1 held 191.1 GB scheduled against a 200.3 GB schedulable
budget on a 250.4 GB disk with a 50.1 GB reserve, which is 95.4 percent of what it could actually
schedule and 76.3 percent of what the alert measured. `zot/data-zot-0`, 80 GiB on the
`longhorn-disposable` class, had been reporting `Scheduled=False` with reason
`LocalReplicaSchedulingFailure` and message `insufficient storage` since 2026-09-06T18:57:31Z,
roughly fifteen hours, with both alerts silent throughout.

## Decision

**Widen the NetworkPolicies to every allocatable gateway pair, not the current one.**
`kubernetes/infrastructure/configs/cnpg/networkpolicies.yaml`,
`kubernetes/infrastructure/controllers/onprem/longhorn/networkpolicies.yaml`, and
`kubernetes/infrastructure/controllers/rancher/networkpolicies.yaml` now enumerate
`10.42.N.0/32` and `10.42.N.1/32` for N from 0 to 7, landed in `825d921c`. Eight slots cover the
three nodes running today, the three-plus-three control-plane goal
[0082](0082-gitops-guardrail-boundary.md) records as unbuilt, and headroom for a Node object
re-registering onto a freed slot rather than the next low one, which is exactly what happened
during the rename.

**Measure Longhorn headroom against the schedulable budget, not raw capacity.** The alert
expressions in `kubernetes/infrastructure/controllers/observability/alert-rules/prometheusrule.yaml`
now divide by `clamp_min(longhorn_node_storage_capacity_bytes - longhorn_node_storage_reservation_bytes, 1)`,
landed in `be5c66a0`. The thresholds and hold durations are unchanged; only the denominator moved.
Both descriptions now say the percentage is of the schedulable budget, disk capacity minus the
per-disk reservation Longhorn withholds from scheduling, rather than raw disk capacity. A promtool
case was added to `tests/promtool/gap-filler_test.yaml` that would have caught the original defect:
scheduled 76, capacity 100, reservation 20, which is 95 percent of the budget and 76 percent of raw
capacity, asserting the warning fires. The corrected alert was confirmed working end to end after
this landed: it went from silent to `pending` for worker-1 at 95.4 percent within minutes of
reconciling.

**Search for the same defect elsewhere, before closing this record.** Every expression in
`kubernetes/infrastructure/controllers/observability/alert-rules/` that divides one metric by
another was checked for a raw capacity or total standing in for a reserved, allocatable, or
requestable figure. `kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes` in
`PersistentVolumeFillingUp` and `PersistentVolumeAlmostFull` measures bytes written against
filesystem capacity as kubelet reports it, which already is the usable figure; there is no separate
reserved quantity kubelet withholds from that number the way Longhorn withholds a per-disk reserve
from scheduling. `container_memory_working_set_bytes / kube_pod_container_resource_limits` in
`ContainerMemoryNearLimit` and `ContainerMemoryAtLimit` compares against the limit itself, which is
the correct denominator by construction. The `slo-blog` recording rules divide error or slow-request
counts by total request counts, not by any capacity figure. No other alert in the estate shares this
defect's shape.

## Options considered

- Widen the NetworkPolicy source to `10.42.0.0/16`, rejected. These policies sit beside a
  `default-deny` NetworkPolicy in each namespace, and the entire point of listing only the `.0` and
  `.1` addresses in each subnet is that those are the only addresses host-originated traffic ever
  uses; every other address in `10.42.0.0/16` belongs to a pod. A `/16` allowlist would let any pod
  in any namespace reach `longhorn-system`, `cattle-system`, and `postgres`, which is a materially
  larger exposure than the gap it closes.
- Match the allowed source by selector instead of by address, rejected as unavailable rather than
  merely undesirable. Host-network traffic originating from the API server and kubelet carries no
  pod or namespace identity for a `podSelector` or `namespaceSelector` to match against. `ipBlock` is
  the only expressible form for this traffic.
- Leave the Longhorn alert thresholds as they were and only fix the denominator's units in the
  description, rejected. The description was not the defect; the expression was. Relabeling raw
  capacity as something it is not would have hidden the same bug under corrected prose.

## Consequences

A node's podCIDR is a property of the Node object, not of the physical node, and a Node object's
replacement moves it. The freed `10.42.0.0/24` was not reused when the rename ran; `10.42.3.0/24`
was allocated instead. Anything in this repository that enumerates pod-network addresses is
therefore fragile across node re-registration specifically, not merely across a change in node
count, and a rename, a rebuild, or a Node object recreated for any reason can reallocate the range
without warning.

Eight slots is itself a bound, not a fix for the underlying fragility. A ninth Node object
allocation, whether from a fourth control plane beyond the goal in [0082](0082-gitops-guardrail-boundary.md)
or from a future re-registration landing outside the range already covered, reintroduces exactly
this failure, and nothing in this repository detects that in advance. This is stated plainly because
the fix closes the incident that already happened, not the class of incident.

The estate reported itself healthy throughout both defects. Nineteen of nineteen Longhorn volumes
were healthy, every pod was Running or Completed, every Flux Kustomization was Ready, while the
control-plane node had no ingress into three namespaces and worker-1 sat at 95.4 percent of its
schedulable storage with the one alert built to catch it silent. Neither defect was visible in any
of the signals an operator would normally check; both were found only by tracing the rename's
consequences and then auditing the alert that should have caught the second one on its own.

The two defects share a shape worth naming for whatever finds the next one: a guardrail that encodes
a derived value, a pod subnet in one case and a denominator in the other, computed once and then
left to go silently wrong when the thing it was derived from moves. Neither guardrail was untested
or unreviewed; both were correct when written and both were invisible once they stopped being
correct, because nothing observed the relationship between the guardrail and the value it depended
on, only the guardrail's own output.

The stale apiserver certificate SANs remain unpruned, for the reasons recorded in
[0083](0083-rename-control-plane-node-to-control-plane-1.md)'s outstanding item. The one relevant
new fact: k3s's `--tls-san-security` flag defaults to `true`, so the SAN set cannot grow further,
which is why leaving the existing surplus names was judged acceptable rather than merely deferred.

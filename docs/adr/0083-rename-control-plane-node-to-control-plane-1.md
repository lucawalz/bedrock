---
status: accepted
date: 2026-09-06
---

# 0083. Rename the control-plane node from master to control-plane-1

## Context

The control-plane node was named `master` throughout this repository: the hostname, the Nix host
directory, the k3s server configuration, the router's DHCP reservation and firewall rules, the
CoreDNS `NodeHosts` entry the workers resolved it through, the agenix secret recipients, the promtool
fixtures and an alert description all named it directly. The workers were already `worker-1` and
`worker-2`, so the one node whose name did not follow the estate's vocabulary was also the one node a
rename is hardest on.

Two hazards stood between deciding this and doing it. The Longhorn `nodes.longhorn.io` object is keyed
by node name rather than by any stable identifier, so a rename orphans that object and its disk
record, and the replicas the node carried have to rebuild from their surviving siblings before it is
healthy again. Verified against the live cluster beforehand, every volume was healthy and no volume
held its only replica on the control-plane node, so the Longhorn side could cost a rebuild but could
not lose data. The second hazard was etcd: k3s was believed to derive its member name from the
hostname at startup, which would leave a renamed node restarting into a datastore whose sole recorded
member no longer matched it. With one member there is no quorum to absorb that, so the only available
mitigation was a fresh, verified snapshot taken immediately beforehand and a known path back to it.

## Decision

Rename the node to `control-plane-1`, but only against a deployed and healthy estate and with a
fresh, verified etcd snapshot in hand.

The precondition is the substance of this decision rather than a caveat on it. When it was written,
nothing in the surrounding pass had been deployed, so renaming then would have left the repository
describing `control-plane-1` while the cluster still answered to `master`, breaking the CoreDNS
`NodeHosts` entry and the workers' join target the moment Flux reconciled. The rename then lands as
one change across every site that names the node, because those sites are not separable: the
apiserver's Subject Alternative Names, the CoreDNS entry and the workers' join target all have to
move in the same window as the hostname, or the operator loses apiserver access during the very
rebuild that is supposed to prove the rename worked. The prepared response to a control plane that
does not return under the new name is restoring that snapshot rather than improvising a repair, by
the procedure in [the disaster-recovery runbook](../disaster-recovery.md).

## Options considered

- Rename against a deployed and healthy estate, chosen. It is the only sequence in which a snapshot
  worth restoring exists and the repository and the cluster agree on the name at every point.
- Rename immediately, alongside the rest of the pass. Rejected. There was no deployed estate to take
  the snapshot against, and the repository and the cluster would have disagreed about the node's name
  until whichever of them changed second.
- Leave the node named `master`. Rejected as a default rather than a choice. The inconsistency is
  cosmetic on its own, but it was the last place the repository's vocabulary did not match itself.
- Rename the workers to a matching scheme as well. Rejected. `worker-1` and `worker-2` already match
  Kubernetes' own vocabulary for a non-control-plane node, and renaming them would multiply the
  Longhorn rebuild this record accepts for no gain over renaming the one name that is wrong.
- Do the etcd side first and the repository-wide rename second. Rejected. The two are not separable,
  for the reason the decision gives.

## Consequences

The rename was executed and verified on 2026-09-07: all three nodes Ready, every volume healthy,
exactly three `nodes.longhorn.io` objects, every Kustomization Ready, and both workers joining by
address. Other records that name the control-plane node were left exactly as written, because each
describes the estate at the time of the decision it records; only the documents that describe the
estate as it currently operates, the disaster-recovery runbook and the README, were updated.

The etcd hazard was misstated, and the sharp step was elsewhere. k3s writes `<nodename>-<uuid8>` to
`/var/lib/rancher/k3s/server/db/etcd/name` on first initialisation and reads that file back on every
later start, so the member name never changed and etcd never saw an identity change. What carried
real risk was deleting the stale `master` Node object. Every Node carries k3s's
`wrangler.cattle.io/managed-etcd-controller` finalizer, and deleting a Node that still holds the
`node-role.kubernetes.io/etcd` label calls `RemovePeer` against the sole etcd member. Two guards
inside `RemovePeer` refuse it, so etcd survives, but the handler errors and the Node hangs in
`Terminating`. Removing the etcd role label first short-circuits the handler on its first guard, and
the deletion then completes cleanly, which is what was done.

Three further surprises belong to any future rename. Applying a hostname is asynchronous, so k3s
restarted before `systemd-hostnamed` had settled, captured `--hostname-override=master` and
registered under the old name until a second restart. The rename allocates a new pod subnet, because
flannel assigns a podCIDR per Node object, so pods created during the transition held addresses that
no longer routed and had to be deleted. And flannel added no VXLAN forwarding entry for the renamed
node on either worker, so every cross-node connection timed out and presented as the Kyverno and
Rancher admission webhooks failing closed rather than as a routing fault, until k3s was restarted on
both workers.

Longhorn cost nothing, because of a defect found while planning and fixed before the rename started.
Longhorn reads the disk identity from `/var/lib/longhorn/longhorn-disk.cfg`, so the new node object
was created carrying the same disk record and the replicas re-homed to it intact without rebuilding.
That outcome depended on `createDefaultDiskLabeledNodes`, which is true in the Longhorn HelmRelease
and means Longhorn creates a default disk only on nodes labelled
`node.longhorn.io/create-default-disk=true`. No node carried that label, and the existing disks
survived only because their node objects had never been deleted. Without it the new node object would
have had no disk at all, and with `replicaSoftAntiAffinity` false and two other nodes, every
three-replica volume would have sat permanently degraded with nowhere to rebuild. Both k3s roles now
set the label.

The stale apiserver certificate Subject Alternative Names were not pruned and remain so, because on a
single-server cluster the delete cannot win: the outgoing k3s process rewrites the `k3s-serving`
Secret from its in-memory cache during shutdown, and the incoming process merges that recreated
Secret back over the correct set. The certificate is valid for every name the node answers to and the
surplus is useless without the private key, so this is a further argument for the three-node control
plane [0082](0082-gitops-guardrail-boundary.md) records as the goal, since a second server would give
the delete somewhere to run from.

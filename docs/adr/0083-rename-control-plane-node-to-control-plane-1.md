---
status: accepted
date: 2026-09-06
---

# 0083. Rename the control-plane node from master to control-plane-1

## Context

The control-plane node is named `master` throughout this repository: the hostname, the Nix host
directory, the k3s server configuration, the router's DHCP reservation and firewall rules, the
CoreDNS `NodeHosts` entry the workers resolve it through, the agenix secret recipients, the
promtool test fixtures, and an alert description all name it directly. `master` also no longer
matches the vocabulary the rest of the estate now uses; the workers are already named `worker-1`
and `worker-2`, and a node called `master` in a cluster whose other nodes carry ordinal names reads
as an inconsistency rather than a description.

Two things stand between deciding this and doing it. The Longhorn `nodes.longhorn.io` object for
this node is keyed by node name, not by any stable identifier, so a rename orphans that object and
its disk record; the sixteen replicas it currently carries have to rebuild from their surviving
siblings before the node can be considered healthy again. And k3s's embedded etcd derives its
member name from the hostname at startup, so a renamed node restarts into a datastore whose sole
recorded member no longer matches the node running it, which is not a state etcd recovers from on
its own.

Verified directly against the live cluster at planning time: all nineteen Longhorn volumes report
`robustness=healthy`. Master holds sixteen replicas, every one part of a three-way set. The only
three single-replica volumes in the estate, `zot/data-zot-0` on worker-2, `llm/ollama` on worker-1,
and `kiwix/kiwix-library` on worker-2, all sit on a worker, not on the control-plane node. No
volume has its only replica on the node this record renames, so the Longhorn side of the rename
cannot lose data outright; it can only cost a rebuild.

The etcd risk has no equivalent safety margin, because there is exactly one etcd member. The only
mitigation available is a fresh, verified snapshot immediately beforehand and a known path back to
it if the restart does not produce a healthy single-member cluster under the new name.

## Decision

Rename the control-plane node from `master` to `control-plane-1`, but not yet: this record's status is
`proposed`, not `accepted`, because the rename depends on preconditions that do not hold today.
Nothing in this pass has been deployed. The owner has not pushed, so the live cluster is still
running every pre-change configuration this pass produced, and performing a rename against an
undeployed, unverified estate would leave the repository describing `control-plane-1` while the cluster
answers to `master`, breaking the CoreDNS `NodeHosts` entry and the agent join target the moment
Flux reconciled. The rename needs a deployed and healthy estate underneath it and a fresh, verified
etcd snapshot taken immediately before it starts, and neither exists yet.

When both preconditions are met, the sequence is:

1. Confirm all nineteen Longhorn volumes are healthy with three replicas where three are
   configured.
2. Take an on-demand etcd snapshot and verify it directly: it exists, its size is consistent with
   the recent snapshot history, and its timestamp is from the current session. Do not proceed on a
   snapshot that is stale or short.
3. Land the configuration change across every site the rename touches: `flake.nix`,
   `lib/inventory.nix`, the host directory, `hosts/common/networking.nix`,
   `modules/k3s/server.nix`, `modules/k3s/agent.nix` for the workers' join target, the router
   firewall and DHCP configuration, `secrets/secrets.nix` and the agenix secret filename, the CI
   workflow that names the node, the CoreDNS `NodeHosts` ConfigMap, any application configuration
   that names the node directly, the promtool test fixtures, and the alert description that names
   it. The Unix user created from the hostname changes with the rename and needs no separate step,
   but is worth confirming rather than assuming.
4. Rebuild the node.
5. Verify the API server returns and the node registers under its new name.
6. Regenerate the apiserver certificate so its Subject Alternative Names match the new name,
   including the new MagicDNS name on the tailnet.
7. Delete the orphaned `nodes.longhorn.io` object left under the old name.
8. Watch the sixteen replicas rebuild to healthy, and do not consider the rename complete until
   every volume is back to three healthy replicas and every Kustomization is Ready.
9. If the API server does not return under the new name, restore from the snapshot taken in step 2
   with `k3s server --cluster-reset --cluster-reset-restore-path=<snapshot>`, which is the
   supported path back for a single-member cluster. Restore rather than improvise a repair.
10. Once the estate is confirmed healthy under the new name, flip this record's status to
    `accepted` in both the frontmatter and the index parenthetical in
    [docs/adr/README.md](README.md), and re-run `scripts/check-adr-index.sh`.

## Options considered

- Rename now, alongside the rest of this pass, rejected. Nothing in this pass is deployed, so there
  is no healthy estate to take the fresh snapshot against, and committing the rename now would
  leave the repository and the live cluster disagreeing about the node's name the moment either one
  changed without the other.
- Leave the node named `master` indefinitely, rejected as the default rather than as a considered
  choice. The naming inconsistency with the two ordinal workers is cosmetic on its own, but it is
  the only remaining place the repository's vocabulary does not match itself, and the rename is
  cheap once the preconditions exist.
- Rename the workers to match a `cp`-style scheme as well, rejected. `worker-1` and `worker-2`
  already match Kubernetes' own vocabulary for a non-control-plane node, and renaming them would
  triple the Longhorn rebuild this record already accepts, from sixteen replicas to the full
  fifty-one the cluster carries, for no gain over renaming the one node whose name is actually
  wrong.
- Perform the etcd side first in isolation, verify it, then do the repository-wide rename as a
  second change, rejected. The two are not separable in practice: the apiserver's own SANs, the
  CoreDNS entry, and the workers' join target all have to change in the same window as the
  hostname, or the workers lose their join target and the operator loses apiserver access using
  the same rebuild that is supposed to prove the rename worked.

## Consequences

Until this record is accepted, the repository states an intended future name that the live cluster
does not carry. Every other record and runbook in this repository that names the control-plane node
still says `master`, and continues to be correct about the estate as deployed, until the rename
lands and each is updated in the same session.

When the rename does proceed, it costs one control-plane restart, one apiserver certificate
regeneration, and a rebuild of sixteen Longhorn replicas from their surviving siblings, none of
which touches data because no volume has its only replica on the node being renamed. The etcd
restart is the step with no partial-failure margin: a single-member cluster either comes back under
its new name or it does not, and the only prepared response to "does not" is restoring the snapshot
taken immediately beforehand, not improvising a repair against a datastore in an unknown state.

The three-plus-three control-plane goal recorded in [0082](0082-gitops-guardrail-boundary.md)
would make this class of restart far less sharp, since a healthy multi-member etcd survives a
single member's identity changing. That hardware does not exist yet, so this rename is undertaken
against the single-member risk as it stands today, not against the risk it will eventually be.

## Update 2026-09-07

The rename has been executed and verified. Nodes `control-plane-1`, `worker-1` and `worker-2` are
all Ready. Nineteen Longhorn volumes are healthy with no degraded three-replica volume. There are
exactly three `nodes.longhorn.io` objects. Every Kustomization is Ready and no pod sits outside
Running or Completed. The CoreDNS `NodeHosts` entry reads `10.20.0.10 control-plane-1`, and both
workers join by address.

**Other records were left as written, by policy.** This record's Consequences said every other
document naming the control-plane node continues to be correct about the estate as deployed until
the rename lands and each is updated in the same session. The rename has landed, and the policy
actually adopted is narrower: those other records stay exactly as written, because each describes
the estate at the time of the decision it records, not the estate as it stands today. Only the
documents that describe the estate as it currently operates, the disaster-recovery runbook and the
README, were updated to the new node name.

**The etcd risk was overstated, and the sharp step was elsewhere.** This record states that k3s
derives its etcd member name from the hostname at startup, so a renamed node meets a datastore
whose sole member no longer matches. That is not what k3s does. `setName` writes
`<nodename>-<uuid8>` to `/var/lib/rancher/k3s/server/db/etcd/name` on first initialisation and
reads that file back on every subsequent start, regenerating only if it is missing. The member name
stayed `master-5ccb6907` throughout the rename, and the node still carries it as its
`etcd.k3s.cattle.io/node-name` annotation. etcd never saw an identity change.

The step that actually carried risk was deleting the stale `master` Node object. k3s registers a
wrangler `OnRemove` handler on Nodes, and every Node carries the
`wrangler.cattle.io/managed-etcd-controller` finalizer. Deleting a Node that still holds the
`node-role.kubernetes.io/etcd` label calls `RemovePeer` against the sole etcd member. Two guards
inside `RemovePeer` refuse it, so etcd survives, but the handler errors and the Node hangs in
`Terminating`. Removing the etcd role label first short-circuits the handler on its first guard, and
the deletion then completes cleanly. That is what was done.

**Three things this record did not anticipate.** First, applying the hostname is asynchronous.
NixOS activation restarted k3s before `systemd-hostnamed` applied the new static hostname, so k3s
captured `--hostname-override=master` and registered under the old name anyway, even though
`/etc/hostname` already read `control-plane-1` while `hostname` still returned `master`. A second
`systemctl restart k3s`, once hostnamed had settled, was needed before the node registered
correctly. Any future rename needs that second restart as an explicit step rather than a discovery.

Second, the rename allocates a new pod subnet. Flannel assigns a podCIDR per Node object, so
`control-plane-1` was given `10.42.3.0/24` where `master` had held `10.42.0.0/24`. Pods created
during the transition kept `10.42.0.x` addresses that no longer routed anywhere and had to be
deleted so their controllers could recreate them. The old subnet's `host-local` IPAM reservations
remain on disk under `/var/lib/cni/networks/cbr0` and are inert, since allocation now comes from the
new range.

Third, and the one that actually broke the cluster for several minutes: flannel did not add the
VXLAN forwarding entry for the renamed node on either worker. Both workers correctly gained the
route `10.42.3.0/24 via 10.42.3.0 dev flannel.1`, but neither had an FDB entry mapping that VTEP MAC
to `100.105.211.67`, so the return path was dead and every cross-node connection timed out. The
visible symptom was not a network error: it was the Kyverno and Rancher admission webhooks failing
closed, which blocked every pod mutation cluster-wide and made the cluster look like an admission
problem rather than a routing one. Restarting k3s on both workers resynchronised flannel and
restored connectivity immediately. This belongs to the same family as the orphaned flannel binding
described in [0074](0074-home-nodes-on-the-tailnet.md) and the `FlannelInterfaceOrphaned` proxy
alert recorded in [0082](0082-gitops-guardrail-boundary.md).

**Longhorn cost nothing, because of a change made specifically to prevent it.** This record expects
sixteen replicas to rebuild from their surviving siblings. They did not rebuild at all. Longhorn
reads the disk identity from `/var/lib/longhorn/longhorn-disk.cfg`, so the new node object was
created with the same disk record, `default-disk-8684c0f54faa244b`, and the sixteen replicas
re-homed to the new node ID intact. Every volume returned to healthy without a rebuild.

That outcome depended on a defect found while planning this rename and fixed before it started.
`createDefaultDiskLabeledNodes` is set to `true` in the Longhorn HelmRelease, which means Longhorn
creates a default disk only on nodes labelled `node.longhorn.io/create-default-disk=true`, and no
node in the estate carried that label. The three existing disks survived only because their node
objects had never been deleted. Without the label, `nodes.longhorn.io/control-plane-1` would have
been created with no disk at all, and with `replicaSoftAntiAffinity` false and two other nodes,
every three-replica volume would have sat permanently degraded with nowhere to rebuild. The label is
now set by both k3s roles. The disk Longhorn creates takes the chart's
`storageReservedPercentageForDefaultDisk` of 30 percent rather than the 20 percent the node carried,
so the reserve was patched back to 50075021312 by hand, which is the practice
[0082](0082-gitops-guardrail-boundary.md) already records for this field.

**Outstanding: the stale certificate SANs were not pruned.** Step 6 of this record expects
regenerating the apiserver certificate to remove roughly twenty accumulated Subject Alternative
Names. It did not, and the mechanism is now understood. On a single-server cluster the delete cannot
win: the outgoing k3s process rewrites the `k3s-serving` Secret from its in-memory cache during
shutdown, and the incoming process computes the correct twelve-entry set and then merges the
recreated thirty-six-entry Secret back over it. Both were observed in the logs one second apart. The
only sequence that prunes them is to delete the Secret and then kill k3s with SIGKILL so it cannot
write back, which is not a reasonable thing to do to the only control-plane node for a cosmetic
gain. The certificate is correctly valid for every name the node answers to, and the surplus names
are useless without the private key. This is left for a future maintenance window, and it is a
further argument for the three-node control plane that [0082](0082-gitops-guardrail-boundary.md)
records as the goal, since a second server would give the delete somewhere to run from.

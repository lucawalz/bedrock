---
status: proposed
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

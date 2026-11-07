---
status: accepted
date: 2026-09-07
---

# 0084. Parameterise the estate for multiple control planes

## Context

Adding a second control-plane machine required editing code rather than data. `lib/default.nix`
carried `assert serverId == 1` and its `mkServer` builder ignored the `serverId` argument entirely,
taking the control-plane hostname from a single `inventory.controlPlane` string.
`modules/k3s/server.nix` set `clusterInit = true` unconditionally, `hosts/common/networking.nix`
wrote one `/etc/hosts` entry for the control plane, `modules/router/firewall.nix` opened port 6443 to
one address, and `flake.nix` and the CI build matrix each named the same three nodes by hand.

None of that was a defect in the single-node estate the cluster runs. It became one the moment a
second control plane was considered, because the fix is spread across five files in three
subsystems, and one of those edits fails in a way that is not obvious from reading the diff: a
second server started with `clusterInit = true` bootstraps its own independent single-member cluster
instead of joining the first.

## Decision

`lib/inventory.nix` becomes the only place a node is declared. Each node carries a `role` of `server`
or `agent`, the file derives `controlPlanes` from those roles, and it names one
`bootstrapControlPlane` explicitly. Two assertions in the same file reject a role outside the two
known values, naming the offending node, and a `bootstrapControlPlane` that is not itself a member of
`controlPlanes`, so a typo is an evaluation failure rather than a node that silently builds as an
agent and drops out of the derived list.

`lib/default.nix` replaces `mkServer` and `mkWorker` with a single `mkNode` that looks the node up in
the inventory, dispatches on its role to import `modules/k3s/server.nix` or `modules/k3s/agent.nix`,
and guards the server-only packages, `KUBECONFIG` and binfmt emulation behind that role. `flake.nix`
consumes a `genAttrs` over every inventory node name in place of the entries it used to list.
`modules/k3s/server.nix` sets `clusterInit` only on the node matching `bootstrapControlPlane` and
gives every other server a `serverAddr` pointing at it, `hosts/common/networking.nix` and
`modules/router/firewall.nix` iterate `controlPlanes` instead of the former singular field, and the
CI build matrix reads the same inventory through `nix eval`, so it can no longer drift from the file
that defines the nodes.

`bootstrapControlPlane` is explicit rather than derived as the first control plane in sort order,
because which node ran `--cluster-init` is a fact about the cluster's history, and a rename or a
reordering must not change which node the rest of the estate treats as the bootstrap.

## Options considered

- Parameterise the inventory and derive everything from it, chosen. It turns a five-file edit across
  three subsystems into one data entry, and it puts the non-obvious `clusterInit` case beyond reach.
- Leave the singular field and edit the code when a second machine arrives. Rejected for the same
  reason: the edits are spread wide and one of them fails silently.
- Derive the bootstrap node as the head of the sorted control-plane list. Rejected, because bootstrap
  status is a historical fact rather than a property that should follow from name ordering.
- Introduce an API virtual address so joining does not depend on one specific node. Rejected for now:
  it is the right answer for the join-time single point of failure and cannot be tested without
  hardware that does not exist yet.
- Rename the roles to k3s's own vocabulary at the hostname level as well. Rejected. The inventory uses
  those words for the role, where they are exact, while the hostnames keep the vocabulary Kubernetes
  uses for the same distinction.

## Consequences

Two etcd members is worse than one, because a two-member cluster loses quorum when either fails. This
change removes the configuration obstacle to a second control plane; it does not make adding one
advisable. The step worth taking is one to three, the hardware goal
[0082](0082-gitops-guardrail-boundary.md) records as unbuilt and unbought. The bootstrap node also
stays a single point of failure for joining rather than for running: an already joined node keeps
working if it goes down, and a node that still needs to join does not.

The inventory schema is now role-dependent. `modules/k3s/server.nix` reads `tailscale.address` and
`tailscale.magicDnsName` from the node's entry and only control planes carry that block, so a new
control-plane entry that omits it fails with a bare missing-attribute error that does not name the
requirement. One inventory entry is also not the whole cost of a new node: it needs an entry in
`secrets/secrets.nix`, its own `tailscale-authkey-<name>.age`, and its host key added to
`k3s-token.age`, which means re-encrypting that file, and a control plane additionally needs a
`hosts/<name>/` directory for its hardware scan. That coupling predates this change and is unaltered
by it. The CI matrix likewise now assumes every inventory node is `x86_64-linux`, which holds because
`mkNode` defaults to it, so a future `aarch64-linux` node would need the matrix changed as well.

Derivation paths could not prove a refactor behaviour-preserving when this was written, because the
`secretsDir = "${self}/secrets"` coupling [0082](0082-gitops-guardrail-boundary.md) records moved
every host's `drvPath` whenever any tracked file changed, the router included. That coupling has
since been closed, so a `drvPath` comparison is usable again for a change that leaves `secrets/`
alone. The gate that replaced it evaluates the option leaves that are semantically meaningful for
the change, including the rendered k3s `ExecStart` rather than only the flag list feeding it, once
before and once after for every host, and diffs the two captures textually.

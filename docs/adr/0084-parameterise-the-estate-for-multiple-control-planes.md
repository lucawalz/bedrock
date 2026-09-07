---
status: accepted
date: 2026-09-07
---

# 0084. Parameterise the estate for multiple control planes

## Context

Before this change, adding a second control-plane machine to the cluster required editing code,
not data. `lib/default.nix` carried `assert serverId == 1`, and its `mkServer` builder ignored the
`serverId` argument entirely, taking the control-plane hostname from a single
`inventory.controlPlane` string. `modules/k3s/server.nix` set `clusterInit = true`
unconditionally, which is correct for exactly one server and wrong for every additional one.
`hosts/common/networking.nix` wrote one `/etc/hosts` entry for the control plane, and
`modules/router/firewall.nix` opened port 6443 to one address. `flake.nix` named every node
individually in `nixosConfigurations`, and the CI build matrix in
`.github/workflows/nix-check.yaml` hardcoded the same three-node list.

None of this was a defect in the single-node estate the cluster runs today. It became a defect the
moment a second control plane was considered, because the fix was spread across five files in
three subsystems, and one of those edits, the unconditional `clusterInit`, fails in a way that is
not obvious from reading the diff: a second server started with `clusterInit = true` bootstraps its
own independent single-member cluster instead of joining the first.

## Decision

`lib/inventory.nix` becomes the only place a node is declared. Each node carries a `role` of
`server` or `agent`; the file derives `controlPlanes`, the list of node names with role `server`,
from those roles, and names one `bootstrapControlPlane` explicitly rather than deriving it. An
assertion rejects any role outside `server` and `agent` and names the offending node.

`lib/default.nix` replaces `mkServer` and `mkWorker` with a single `mkNode { hostname, ... }` that
looks up the node in the inventory, dispatches on its role to import `modules/k3s/server.nix` or
`modules/k3s/agent.nix`, and guards the server-only packages, `KUBECONFIG`, and binfmt emulation
with `lib.mkIf isServer`. `clusterNodes`, a `genAttrs` over every inventory node name calling
`mkNode`, is exported and consumed wholesale by `flake.nix` in place of the three named
`nixosConfigurations` entries. `modules/k3s/server.nix` sets `clusterInit` only on the node whose
hostname matches `bootstrapControlPlane` and gives every other server a `serverAddr` pointing at
the bootstrap node's address on port 6443. `hosts/common/networking.nix` and
`modules/router/firewall.nix` both iterate `inventory.controlPlanes` instead of reading the single
former field, rendering one `/etc/hosts` entry or firewall rule per control plane. The CI build
matrix reads the same inventory through a new `inventory` job that runs
`nix eval --json --file lib/inventory.nix` and feeds the result to `build-x86` as `fromJSON(...)`,
so the matrix can no longer drift from the file that actually defines the nodes.

`bootstrapControlPlane` is explicit rather than derived as the first control plane in sort order,
because which node ran `--cluster-init` is a fact about the cluster's history, not something to
infer from alphabetical ordering. A rename or a reordering of the inventory must not change which
node the rest of the estate treats as the bootstrap.

## Options considered

- Leave the singular field and edit the code when a second machine arrives. Rejected. The edits are
  spread across five files in three subsystems, and one of them, the unconditional `clusterInit`,
  fails in a way that is not obvious from reading the diff.
- Derive the bootstrap node as the head of the sorted control-plane list. Rejected for the reason
  above: bootstrap status is a historical fact, not a property that should follow from name
  ordering.
- Introduce an API virtual address or a fixed registration address so that joining does not depend
  on one specific node. Rejected for now. It is the right answer for removing the join-time single
  point of failure, and it cannot be tested without hardware that does not exist yet.
- Rename the roles to k3s's own `server` and `agent` vocabulary at the hostname level as well.
  Rejected. The inventory uses those words for the role, where they are exact, while the hostnames
  stay `control-plane-1` and `worker-N`, which is the vocabulary Kubernetes itself uses for the
  same distinction.

## Consequences

Two etcd members is worse than one. A two-member cluster loses quorum when either member fails, so
it is less available than the single member the estate runs today. This change removes the
configuration obstacle to a second control plane; it does not make adding one advisable. The step
worth taking is one to three, which is the hardware goal
[0082](0082-gitops-guardrail-boundary.md) already records as unbuilt and unbought.

The bootstrap node is a single point of failure for joining, not for running. Every agent and every
additional server resolves its join address to `bootstrapControlPlane`. An already-joined node
keeps working if that node goes down; a node that still needs to join does not.

The inventory schema is now role-dependent. `modules/k3s/server.nix` reads `tailscale.address` and
`tailscale.magicDnsName` from the node's inventory entry, and only control planes carry that block
today. A new control-plane entry that omits it fails with a bare missing-attribute error that does
not name the requirement.

One inventory entry is not the whole cost of a new node. It also needs an entry in
`secrets/secrets.nix`, its own `tailscale-authkey-<name>.age`, and its host key added to
`k3s-token.age`, which means re-encrypting that file. A control plane additionally needs a
`hosts/<name>/` directory for its hardware scan. This coupling predates the change and is
unaltered by it.

`role` is a free-form string. Where the role used to be structural, chosen by calling `mkServer` or
`mkWorker`, a typo now produces a node that silently builds as an agent and drops out of the
derived control-plane list, losing its `/etc/hosts` entry and its firewall rule along with it. An
assertion in `lib/inventory.nix` rejects any role outside the two known values and names the
offending node, which turns that typo into a hard evaluation failure instead of a silent
misconfiguration; the assertion was added in a fix round after the initial commit, once this exact
failure mode was raised.

The CI build matrix now assumes every inventory node is `x86_64-linux`. That holds today because
`mkNode` defaults to it and nothing in the inventory overrides it, but the inventory itself no
longer guarantees it; a future `aarch64-linux` node would need the matrix, not just the inventory,
to change.

Derivation paths cannot be used to prove a refactor is behaviour-preserving in this repository.
[0082](0082-gitops-guardrail-boundary.md) records that `secretsDir = "${self}/secrets"` ties every
host's closure hash to the content-addressed store path of the whole flake source, not just
`secrets/`. This change is the first to test that in anger. An acceptance gate was written
requiring `nix eval --raw .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath` to
come back byte-identical to a baseline captured before any file in the repository was touched. It
did not, for every host, including the router, which imports no file this change touches. The
divergence was traced with `nix derivation show` to a single input: the embedded `secretsDir`
store path baked into each host's `activate` derivation through its `age.secrets.*.file`
arguments. `"${self}"` string-coerces the entire flake source tree, git-tracked files included,
into one content-addressed path, so that path's hash moves whenever any tracked file's content
changes anywhere in the repository, whether or not the host in question imports that file. This was
confirmed as pre-existing and unconditional, not a defect introduced by this change, with an
isolated experiment: a single, semantically irrelevant edit to `modules/router/firewall.nix`,
committed alone, then diffed against the flake source it never had before the edit, still produced
a `drvPath` divergent from baseline, identical to what the same edit produced in a dirty working
tree.

The consequence for method, not just for this change: a byte-identical `drvPath` comparison cannot
be satisfied by any refactor that edits more than one tracked file in this repository, which rules
it out as a general-purpose behaviour-preservation gate here. The gate that replaced it compares
evaluated configuration instead of derivation paths, and is reproducible from three ingredients.
First, decide which option leaves are semantically meaningful for the change under review, not
every option in the module system; for this change that meant `networking.hostName`,
`networking.hosts`, `networking.firewall.allowedTCPPorts`, the k3s `role`, `serverAddr`,
`clusterInit`, `extraFlags`, and `enable`, `boot.binfmt.emulatedSystems`, `environment.variables`
and `environment.systemPackages`, `users.users`, `age.secrets`, the two Tailscale flag lists,
`system.stateVersion`, and, critically, the rendered `systemd.services.k3s.serviceConfig.ExecStart`
unit rather than only the `extraFlags` list that feeds it, so that flag ordering is compared and
not just the flag set. Second, evaluate each of those leaves with `nix eval --json
.#nixosConfigurations.<host>.config.<leaf>`, once against the tree before the change and once
after, for every host the change can plausibly affect; this repository has four,
`control-plane-1`, `worker-1`, `worker-2`, and `router`, and the router needs
`config.networking.nftables.tables."nixos-fw".content` rather than
`config.networking.nftables.ruleset`, which is left at its default empty string when the firewall
is configured through `networking.firewall.extraForwardRules` as this repository does. Third, diff
the two captures textually. Applied here across fifty-seven option leaves over all four hosts, they
matched apart from one intended difference: opening port 6443 to a list rather than a single
address renders `ip daddr { 10.20.0.10 }` where it previously rendered `ip daddr 10.20.0.10`, which
nftables treats identically. Any future refactor in this repository that touches more than one
tracked file needs this same method, because the derivation-path shortcut is not available to it.

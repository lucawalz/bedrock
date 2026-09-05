---
status: accepted
date: 2026-09-05
---

# 0080. Retire Grocy and withdraw its public exposure

## Context

[0079](0079-public-grocy-with-scoped-api-bypass.md) deployed Grocy and published it at
`grocy.syslabs.dev` through the Cloudflare tunnel, on the argument that grocery tracking is only
worth having if a phone can reach it from a shop. That argument depended on the application being
used, and it is not. The native client the path-scoped bypass exists for was never adopted either.

What is left is the cost without the benefit that justified it. A fourth host is public, one prefix
of it is reachable with no edge authentication beyond Cloudflare Access, a 2Gi Longhorn volume is
replicated three ways and copied to the backup target every night, and the exposure depends on two
Cloudflare Access applications that sit outside the GitOps loop and have to be remembered. Narrowing
any of that would leave the same unused application behind a smaller surface, so the honest fix is
removal rather than a tightening.

## Decision

Remove Grocy. The application, its namespace, the `grocy.syslabs.dev` tunnel entry, the Traefik
egress peer that let the router reach its namespace, and the AdGuard split-horizon rewrite all go
together. The tunnel returns to the three hosts it carried before 2026-08-31, `chat`,
`lucawalz.dev` and `rancher`, which is the list the README and the title of
[0014](0014-declarative-minimal-cloudflare-exposure.md) already describe.

The data is deleted rather than archived. Its Longhorn backups are purged explicitly at the same
time, because Longhorn does not collect backups when the volume they came from is deleted, and a
retention window only prunes on a new backup that will never be taken. Left alone they would sit on
the backup target indefinitely, which is the storage equivalent of the Authentik provider that 0079
removed as drift.

This supersedes [0079](0079-public-grocy-with-scoped-api-bypass.md). That record is kept at full
length: its reasoning about scoping an unauthenticated prefix at the edge is still live, because the
same shape guards the agent registration paths on rancher under
[0059](0059-outbound-only-peers-via-public-rancher.md).

## Options considered

- Remove the application, chosen. Nothing depends on it, it holds no data worth keeping, and every
  piece of it is declared in the repository, so the removal is one reviewable diff plus the two
  dashboard-managed objects that were always manual.
- Keep it internal and drop only the tunnel entry, rejected. It would retire the public surface,
  which is the part that carries risk, but leave a replicated volume, a nightly backup and an
  application to patch in service of nothing.
- Keep it deployed and scale it to zero, rejected. The manifests, the namespace, the volume and the
  backups would all remain, and a scaled-down workload is harder to notice as dead than an absent
  one.

## Consequences

The public surface is back to three hosts. The `/api/` prefix, the only unauthenticated path in the
estate that did not belong to an unattended agent, is gone.

Two parts of the removal are manual, for the same reason [0014](0014-declarative-minimal-cloudflare-exposure.md)
records the additions as manual: the `grocy.syslabs.dev` DNS record and both Cloudflare Access
applications are dashboard-managed. A stranded Access application is harmless once the DNS record is
gone, but it is drift, and nothing in the repository will report it.

Velero's `daily-dr` schedule captured Grocy's claim and volume objects as metadata rather than file
data, so those copies need no action and expire on their own within a week.

Reversing this decision means deploying Grocy again from scratch. No backup is kept, so the
inventory would start empty.

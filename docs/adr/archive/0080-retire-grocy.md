---
status: accepted
date: 2026-09-05
---

# 0080. Retire Grocy and withdraw its public exposure

## Context

[0079](0079-public-grocy-with-scoped-api-bypass.md) published Grocy at `grocy.syslabs.dev` through
the Cloudflare tunnel, on the argument that grocery tracking is only worth having if a phone can
reach it from a shop. The application is not used, and the native client the path-scoped bypass
exists for was never adopted. What remains is a fourth public host, one prefix of it reachable with
no edge authentication beyond Cloudflare Access, a replicated and nightly-backed-up volume, and two
dashboard-managed Access applications to remember.

## Decision

Remove Grocy: the application, its namespace, the tunnel entry, the Traefik egress peer that let the
router reach its namespace, and the AdGuard split-horizon rewrite. The tunnel returns to the three
hosts it carried before, `chat`, `lucawalz.dev` and `rancher`, which is the list
[0014](0014-declarative-minimal-cloudflare-exposure.md) already describes. The data is deleted rather
than archived and its Longhorn backups are purged explicitly, because Longhorn does not collect
backups when the volume they came from is deleted and a retention window only prunes on a new backup
that will never be taken. This supersedes [0079](0079-public-grocy-with-scoped-api-bypass.md), which
keeps its reasoning about scoping an unauthenticated prefix at the edge.

## Options considered

- Remove the application, chosen. Nothing depends on it, it holds no data worth keeping, and every
  piece is declared in the repository bar two dashboard-managed objects that were always manual.
- Keep it internal and drop only the tunnel entry, rejected. It retires the part that carries risk
  and leaves a replicated volume, a nightly backup and an application to patch for nothing.
- Keep it deployed and scale it to zero, rejected. Everything remains, and a scaled-down workload is
  harder to notice as dead than an absent one.

## Consequences

The public surface is back to three hosts, and the `/api/` prefix, the only unauthenticated path in
the estate that did not belong to an unattended agent, is gone. The rancher bypass that did belong to
one was withdrawn later still, so nothing public is reachable now without authentication. The DNS
record and both Access applications are dashboard-managed and go by hand, for the reason
[0014](0014-declarative-minimal-cloudflare-exposure.md) records, so a stranded Access application is
drift that nothing in the repository will report. Reversing this decision means deploying Grocy again
from scratch, with an empty inventory, because no backup is kept.

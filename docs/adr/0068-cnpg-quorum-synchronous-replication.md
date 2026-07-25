---
status: accepted
date: 2026-07-25
---

# 0068. Commit Postgres writes to a quorum of one standby, preferring availability

## Context

The `postgres` CloudNativePG cluster runs three instances, one per node since the placement fix that accompanied this record. Until now its manifest carried no `postgresql.synchronous` stanza and neither of the legacy `minSyncReplicas` or `maxSyncReplicas` fields, so `synchronous_standby_names` was empty on the primary and every standby reported `sync_state: async`.

That is CloudNativePG's default, and defaults are not decisions. The consequence was never weighed: a commit was acknowledged to the client as soon as the primary flushed it locally, with no standby having received it. Losing the primary between the flush and the next stream would lose those transactions, and the databases behind it hold the authentik identity store, the paperless document index, and the miniflux feed state.

The durability question is separate from the backup question. Barman archives WAL continuously to object storage and gives point-in-time recovery with a recovery point measured in minutes, but that is a recovery mechanism, not a commit guarantee. Nothing in the estate stated what a successful commit was meant to promise.

Three instances is the smallest cluster where a synchronous choice is meaningful. With two, requiring a standby confirmation means the loss of either instance stops writes entirely, which trades more availability than the durability is worth. With three, one standby can be lost and a second can still acknowledge.

## Decision

Set quorum-based synchronous replication with one required acknowledgement, and let the primary continue when no standby can provide it:

```yaml
postgresql:
  synchronous:
    method: any
    number: 1
    dataDurability: preferred
```

`method: any` selects PostgreSQL's quorum form, `ANY 1 (...)`, rather than the priority-ordered `first`. Any one of the two standbys satisfies the commit, so the cluster does not care which node is lost. Priority ordering would name a preferred standby and gain nothing here, because both standbys are equivalent hardware on equivalent links.

`number: 1` is the quorum size. Two would require both standbys and make any single node loss stop writes, which is the outcome this record exists to avoid.

`dataDurability: preferred` is the availability half of the decision. Under `required`, CloudNativePG keeps unavailable standbys in `synchronous_standby_names`, so a commit blocks until quorum returns and a node loss becomes a write outage. Under `preferred`, the operator removes standbys that cannot acknowledge, and the cluster degrades to asynchronous commit rather than refusing writes. The guarantee is therefore best-effort: writes are durable on two nodes whenever two nodes are available, and durable on one when they are not.

`dataDurability` only applies while `standbyNamesPre` and `standbyNamesPost` are both unset, so neither is set.

## Options considered

**Leave replication asynchronous.** The status quo, and the cheapest. Rejected because it was never chosen: it was inherited from a default, and the window it opens is unbounded by anything the estate measures. Writing the choice down is most of the value here, whichever way it goes.

**`dataDurability: required` with `number: 1`.** Genuinely stronger: a commit is never acknowledged unless a second node holds it. Rejected because at three nodes with one operator, a node reboot during routine maintenance would stop writes to three applications until it returned. The estate has no on-call rotation and no second site, so an availability failure is more likely to cause real harm than the narrow durability window it closes.

**`number: 2`.** Rejected for the same reason, more severely: it removes single-node-loss tolerance altogether.

**The legacy `minSyncReplicas` and `maxSyncReplicas` fields.** These still exist in the 1.30 CRD but predate the quorum API and cannot express either the method or `dataDurability`. Rejected as deprecated; the `postgresql.synchronous` stanza is the supported form from 1.24 onward. The two must not be combined.

## Consequences

A commit now waits for one standby to confirm receipt before returning, so write latency includes a network round trip within VLAN 20 rather than only a local flush. On a wired local network between three nodes this is sub-millisecond, and the workloads are low-throughput, so the cost is not expected to be observable.

Losing one node leaves one standby able to acknowledge and the guarantee intact. Losing two leaves the primary writing asynchronously and still serving, which is the behaviour `preferred` is chosen for, and it happens silently. `pg_stat_replication` reporting `sync_state: async` on a running cluster is the signal that the guarantee has degraded, and nothing currently alerts on it.

The switchover that moves the primary does not change any of this, because the quorum is expressed over whichever instances are standbys at the time rather than over named nodes.

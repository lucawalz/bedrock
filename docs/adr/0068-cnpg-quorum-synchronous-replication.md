---
status: accepted
date: 2026-07-25
---

# 0068. Commit Postgres writes to a quorum of one standby, preferring availability

## Context

The `postgres` CloudNativePG cluster runs three instances, one per node since the placement fix that accompanied this record. Its manifest carried no `postgresql.synchronous` stanza and neither of the legacy `minSyncReplicas` or `maxSyncReplicas` fields, so `synchronous_standby_names` was empty on the primary and every standby reported `sync_state: async`. That is CloudNativePG's default, and defaults are not decisions. The consequence was never weighed: a commit was acknowledged to the client as soon as the primary flushed it locally, with no standby having received it, and the databases behind it hold the authentik identity store, the paperless document index, and the miniflux feed state.

The durability question is separate from the backup question. Continuous write-ahead-log archiving gives point-in-time recovery with a recovery point measured in minutes, but that is a recovery mechanism rather than a commit guarantee, and nothing in the estate stated what a successful commit was meant to promise. Three instances is the smallest cluster where a synchronous choice is meaningful: with two, requiring a standby confirmation means the loss of either instance stops writes entirely, while with three one standby can be lost and a second can still acknowledge.

## Decision

Set quorum-based synchronous replication with one required acknowledgement, and let the primary continue when no standby can provide it:

```yaml
postgresql:
  synchronous:
    method: any
    number: 1
    dataDurability: preferred
```

`method: any` selects PostgreSQL's quorum form, `ANY 1 (...)`, rather than the priority-ordered `first`, so either standby satisfies the commit and the cluster does not care which node is lost. Priority ordering would name a preferred standby and gain nothing, because both standbys are equivalent hardware on equivalent links. `number: 1` is the quorum size; two would require both standbys and make any single node loss stop writes, which is the outcome this record exists to avoid. `dataDurability: preferred` is the availability half of the decision. Under `required`, CloudNativePG keeps unavailable standbys in `synchronous_standby_names`, so a commit blocks until quorum returns and a node loss becomes a write outage. Under `preferred`, the operator removes standbys that cannot acknowledge and the cluster degrades to asynchronous commit rather than refusing writes. The guarantee is therefore best-effort: writes are durable on two nodes whenever two nodes are available, and durable on one when they are not. The field only applies while `standbyNamesPre` and `standbyNamesPost` are both unset, so neither is set.

## Options considered

- Quorum of one with `dataDurability: preferred`, chosen. It states a guarantee the estate never stated, and it degrades to asynchronous commit rather than to a write outage.
- Leave replication asynchronous. Rejected because it was never chosen: it was inherited from a default, and the window it opens is unbounded by anything the estate measures.
- `dataDurability: required` with `number: 1`. Stronger, since a commit is never acknowledged unless a second node holds it. Rejected because at three nodes with one operator, a node reboot during routine maintenance would stop writes to three applications until it returned, and an availability failure with no on-call rotation is more likely to cause real harm than the narrow durability window it closes.
- `number: 2`. Rejected for the same reason, more severely: it removes single-node-loss tolerance altogether.
- The legacy `minSyncReplicas` and `maxSyncReplicas` fields. Rejected as deprecated. They predate the quorum API and cannot express either the method or `dataDurability`, and the two forms must not be combined.

## Consequences

A commit now waits for one standby to confirm receipt before returning, so write latency includes a network round trip within VLAN 20, which is sub-millisecond on a wired local network between three low-throughput nodes. Losing one node leaves one standby able to acknowledge and the guarantee intact. Losing two leaves the primary writing asynchronously and still serving, which is the behaviour `preferred` is chosen for, and it happens silently: `pg_stat_replication` reporting `sync_state: async` on a running cluster is the signal that the guarantee has degraded, and nothing alerts on it. A switchover that moves the primary changes none of this, because the quorum is expressed over whichever instances are standbys at the time rather than over named nodes. The separation this record draws between durability and recovery was tested by the archiver leaving and returning. [0081](0081-retire-the-hetzner-account.md) removed the Barman archiver with the Hetzner account, leaving the quorum commit as the only thing behind the commit guarantee, and its 2026-09-12 update restored base backups and continuous archiving against the in-cluster MinIO instance, so point-in-time recovery exists again inside a 30 day window. The quorum commit is still the only protection against a primary loss and protects against nothing else, because a bad write reaches every replica.

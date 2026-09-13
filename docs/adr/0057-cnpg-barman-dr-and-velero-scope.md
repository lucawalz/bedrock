---
status: accepted, backup mechanisms superseded by 0081
date: 2026-07-04
---

# 0057. CloudNativePG native Barman DR and Velero scope

## Context

[0046](0046-cloudnative-pg-declarative-postgres.md) moved Postgres onto CloudNativePG but explicitly deferred backups, leaving the recovery story as the Longhorn volume snapshot captured by Velero. That left two gaps. A volume snapshot restores the volume as it was at snapshot time and cannot replay to an arbitrary moment, so a logical fault written just before the next daily backup is unrecoverable between snapshots. And Velero captured the live data volume while the database was running, which is a crash-consistent copy of files the engine may be mid-write on rather than a database-consistent backup. The same schedule also captured data the cluster can rebuild at no cost: the Ollama model volumes hold weights that are re-pulled on demand, and the monitoring namespace holds derived, short-lived telemetry.

Three facts constrained the change. The `postgres` namespace ran a default-deny egress policy with no rule for outbound 443, so a Barman archiver would fail to reach object storage and WAL archiving would silently stall. The CNPG Barman Cloud plugin was not installed, so the backup had to use the in-tree `barmanObjectStore` stanza. And Velero ran with `deployNodeAgent: false`, so it took no file-level copies of its own and its volume durability rode the CSI VolumeSnapshot path, which for Longhorn volumes is Longhorn's own BackupTarget writing to the same object storage.

## Decision

Give CloudNativePG a native Barman object-store backup for point-in-time recovery, then narrow Velero so it stops double-capturing Postgres and stops capturing re-derivable data. The two halves are sequenced: Barman must be proven before Velero is narrowed, so the database is never left without a working backup.

Barman writes to a dedicated bucket, separate from the one Velero and Longhorn share, so Postgres backups have their own lifecycle and credentials. The cluster gains a `backup.barmanObjectStore` stanza with WAL and data both gzip-compressed and a 30 day retention policy, and a `ScheduledBackup` takes a base backup daily. The archiver authenticates with its own S3 key pair, and because continuous WAL archiving depends on the egress fix, the network policy gains an outbound 443 rule mirroring the existing 6443 rule, allowing the public internet while excluding the pod and service CIDRs.

Once continuous archiving is confirmed healthy and a base backup has completed, Velero is narrowed. The cluster carries `inheritedMetadata` labelling every object it owns with `velero.io/exclude-from-backup: "true"`, which drops the Postgres data volumes from Velero while leaving pgAdmin, which is not a cluster-owned object, still captured. The daily schedule adds the monitoring namespace to its exclusions, the Ollama vision model volume moves to the `longhorn-disposable` storage class, and a Velero volume policy skips any volume on that class so re-derivable model weights are never snapshotted.

## Options considered

- Keep Velero volume snapshots as the only Postgres recovery path. This is the status quo from [0046](0046-cloudnative-pg-declarative-postgres.md). It gives no point-in-time recovery and captures the data volume while the engine is writing, treating storage-layer durability as if it were database backup.
- Install the CNPG Barman Cloud plugin and back up through it. This is the direction CloudNativePG is moving, but it adds an operator-side component and CRDs to install and reconcile for no capability the in-tree stanza lacks at this scale.
- Barman to the shared backup bucket. Reusing it avoids provisioning a second one but couples Postgres retention and credentials to the estate backup bucket, so a scoped least-privilege key and an independent lifecycle are not possible.
- Exclude re-derivable volumes with per-PVC labels instead of a storage class. Labelling each volume works but scatters the intent across resources and is easy to forget on the next volume, where routing re-derivable data through one class expresses the rule once.

## Consequences

Postgres gained point-in-time recovery: a base backup plus a continuous WAL stream can replay the database to any moment inside the retention window, which the volume snapshot could never do, and the recovery path became database-consistent rather than crash-consistent. The egress rule is load-bearing and comes first, because without outbound 443 the archiver fails quietly while the WAL backlog grows on the primary.

The de-duplication half was not achieved as written. Velero honoured the exclusion label, but that label means nothing to Longhorn, which assigns every volume carrying no recurring-job label to the `default` group that its backup job targets, so all three Postgres data volumes went on being captured crash-consistent every night. Correcting it meant labelling the volumes out of the `default` group through `inheritedMetadata`, which requires `recurring-job.longhorn.io/source: enabled` before Longhorn reads PVC labels at all. A second duplication was introduced rather than removed at the same time: the Velero VolumeSnapshotClass carried no `parameters`, so Longhorn's CSI driver produced an object-store backup rather than a local snapshot and every volume Velero touched was written to the shared bucket twice nightly. That was closed by setting the class to `type: snap`, confirmed live, and the class itself is gone with Velero.

The separate credential this record claimed was also weaker than described. The Barman key pair was distinct from the one Velero, Longhorn and k3s shared, but Hetzner key pairs are project-wide by default and no bucket policy existed on either bucket, so both keys carried full control over both. The separation was organisational rather than enforced, and the claimed blast-radius reduction did not hold.

Both mechanisms this record decided went with the Hetzner account under [0081](0081-retire-the-hetzner-account.md), which removed Barman, its scheduled backup, the outbound 443 rule, and Velero in full. Barman has since returned on the same shape decided here, pointed at an in-cluster MinIO bucket, so point-in-time recovery inside the retention window is restored and the nightly Longhorn snapshot the Postgres volumes now carry directly is a fallback rather than the only mechanism. What stays superseded is the destination rather than the decision: this is an in-cluster copy, so it answers none of the fire, theft or flood scenarios [0081](0081-retire-the-hetzner-account.md) accepted losing, and the off-site gap that record describes is unchanged. Re-derivable model weights still sit on the `longhorn-disposable` class, unaffected by any of it.

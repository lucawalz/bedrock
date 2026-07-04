---
status: accepted
date: 2026-07-04
---

# 0057. CloudNativePG native Barman DR and Velero scope

## Context

ADR 0046 moved Postgres onto CloudNativePG but explicitly deferred backups: the recovery story stayed the Longhorn volume snapshot captured by Velero, with a note that a Barman object-store backup understanding point-in-time recovery was a later addition. That leaves two gaps. A Longhorn snapshot restores the volume as it was at snapshot time and cannot replay to an arbitrary moment, so a logical fault written just before the next daily backup is unrecoverable between snapshots. And Velero captures the live Postgres data volume while the database is running, which is a crash-consistent copy of files the engine may be mid-write on, not a database-consistent backup.

The same Velero schedule also captures data the cluster can rebuild from source at no cost. The Ollama model volumes hold weights that are re-pulled on demand, and the monitoring namespace holds telemetry that is derived and short-lived. Backing these up spends object-storage capacity and backup windows on bytes that never need restoring.

Three facts constrain the change. The `postgres` namespace runs a default-deny egress policy whose only allowances are in-cluster DNS, peer replication, the operator webhook, and the Kubernetes API on 6443; there is no rule for outbound 443, so a Barman archiver would fail to reach object storage and WAL archiving would silently stall. The CNPG Barman Cloud plugin is not installed, so the backup must use the in-tree `barmanObjectStore` stanza, which CNPG 1.29 still supports. Velero runs with `deployNodeAgent: false`, so it takes no file-level volume copies of its own; its volume durability rides the CSI VolumeSnapshot path, which for Longhorn volumes is Longhorn's own BackupTarget writing to the same object storage.

## Decision

Give CloudNativePG a native Barman object-store backup for point-in-time recovery, then narrow Velero so it stops double-capturing Postgres and stops capturing re-derivable data. The two halves are sequenced: Barman must be proven before Velero is narrowed, so the database is never left without a working backup.

Barman writes to a dedicated bucket `basalt-cnpg-backups` in Helsinki, separate from the `basalt-backups` bucket that Velero and Longhorn share, so Postgres backups have their own lifecycle and credentials. The `postgres` cluster gains a `backup.barmanObjectStore` stanza with WAL and data both gzip-compressed and a 30 day retention policy, and a `ScheduledBackup` takes a base backup daily at 03:00. The archiver authenticates with a scoped S3 key pair held in the `cnpg-backup-s3` secret. Continuous WAL archiving depends on the egress fix, so the network policy gains an outbound 443 rule mirroring the existing 6443 rule, allowing the public internet while excluding the pod and service CIDRs.

Once continuous archiving is confirmed healthy and a base backup has completed, Velero is narrowed. The cluster carries `inheritedMetadata` labelling every object it owns with `velero.io/exclude-from-backup: "true"`, which drops the Postgres data volumes from Velero cleanly while leaving pgAdmin, which is not a cluster-owned object, still captured. The daily schedule adds the monitoring namespace to its exclusions alongside paperless. The Ollama vision model volume moves to the `longhorn-disposable` storage class, matching the existing Ollama volume, and a Velero volume policy skips any volume on that class so re-derivable model weights are never snapshotted.

## Options considered

- Keep Velero volume snapshots as the only Postgres recovery path. This is the ADR 0046 status quo. It gives no point-in-time recovery and captures the data volume while the engine is writing, so the copy is crash-consistent at best. It treats storage-layer durability as if it were database backup.
- Install the CNPG Barman Cloud plugin and back up through it. This is the direction CNPG is moving, but it adds an operator-side component and CRDs to install and reconcile for no capability the in-tree stanza lacks at this scale. The in-tree `barmanObjectStore` is supported in 1.29 and is the smaller surface.
- Barman to the shared `basalt-backups` bucket. Reusing the Velero and Longhorn bucket avoids provisioning a second one but couples Postgres retention and credentials to the estate backup bucket, so a scoped least-privilege key and an independent lifecycle are not possible. A separate bucket keeps the blast radius of the backup credential to Postgres alone.
- Exclude re-derivable volumes with per-PVC labels instead of a storage class. Labelling each volume works but scatters the intent across resources and is easy to forget on the next volume. Routing re-derivable data through `longhorn-disposable` and skipping that class in one Velero policy expresses the rule once.

## Consequences

Postgres gains point-in-time recovery: a base backup plus a continuous WAL stream can replay the database to any moment inside the 30 day window, which the volume snapshot could never do. The recovery path is now database-consistent rather than crash-consistent. The cost is a dedicated bucket and a scoped S3 key that must exist before the cluster reconciles, and an operator action to create and encrypt them: the `cnpg-backup-s3` secret with keys `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY` must be written to `kubernetes/clusters/home/secrets/apps/cnpg-backup-s3.sops.yaml` in namespace `postgres`, SOPS-encrypted, and added to that directory's kustomization before the change is pushed, or the archiver cannot authenticate.

The egress rule is load-bearing and comes first: without outbound 443 the archiver fails quietly and the WAL backlog grows on the primary. The Velero narrowing is deliberately staged after Barman is verified, because it removes the only prior Postgres backup, so it must not land until the continuous-archiving status is healthy and a base backup has completed. Until then the two coexist and Postgres is doubly protected.

Velero's scope shrinks to the data that genuinely needs off-cluster capture. It no longer snapshots the Postgres volumes, the monitoring telemetry, or the model weights, which reduces backup size and window. Because Velero runs with the node agent disabled, its volume durability for what remains rides Longhorn's BackupTarget writing to the shared bucket, so the CSI snapshot path and the Longhorn backup are the real durability mechanism for non-Postgres volumes; the Velero exclusions change what is offered to that path, not a separate copy. The Ollama vision volume move is a one-time model re-pull on the disposable class, accepted because the weights are re-derivable by design.

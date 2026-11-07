---
status: accepted
date: 2026-09-06
---

# 0081. Retire the Hetzner account and accept an estate with no off-site backups

## Context

The Hetzner Cloud account the estate has depended on since [0009](0009-velero-backups.md) is being
closed. That is an external event rather than a design choice, so the question this record settles is
not whether to leave Hetzner but what to do about the capabilities that leave with it. Velero wrote
resource backups to `basalt-backups`, Longhorn's `backup` RecurringJob wrote volume backups to the
same bucket ([0005](0005-longhorn-storage.md)), k3s uploaded its etcd snapshots there
([0064](0064-off-node-etcd-s3-snapshots.md)), and CloudNativePG's Barman archiver wrote base backups
and a continuous write-ahead-log stream to a second bucket
([0057](0057-cnpg-barman-dr-and-velero-scope.md)). Horizon separately leased servers through the
hcloud API to add capacity beyond the three home nodes
([0071](0071-deploy-horizon-operator-from-published-chart.md)).

Velero's contribution was smaller than [0009](0009-velero-backups.md) claims. `snapshotMoveData` was
off and no `DataUpload` object was ever recorded, so no volume bytes left through Velero; what it put
off-site was the estate's Secrets and its claim-to-volume bindings, while volume durability rode
Longhorn's own BackupTarget. The intended replacement is a NAS in the rack, chosen but not bought and
deferred on cost, so treating it as imminent would be planning around something that does not exist.

## Decision

Remove every mechanism that depended on the account rather than repointing it at a substitute
provider, and run without an off-site copy until the NAS exists.

What goes: Velero in full, meaning its HelmRelease, the `daily-dr` schedule, the VolumeSnapshotClass,
the volume policy, its network policies, the velero-ui application and the namespace; the Longhorn
BackupTarget and its `backup` RecurringJob; the barman-cloud plugin with its ObjectStore and
ScheduledBackup, and the outbound 443 rule the archiver needed; the k3s `--etcd-s3*` flags and their
secret; horizon's Hetzner ProviderConfig, the `cluster-horizon-provider` Kustomization and the hcloud
egress policy; the weekly schedule on the Packer snapshot build; the alert groups that watched all of
it; and the matching credentials in `bedrock-secrets`
([0060](0060-private-secrets-repo-per-cluster-keys.md)).

What stays is everything that does not need object storage: Longhorn's three-way replication and its
recurring jobs, with a nightly snapshot retaining 7 and `snapshot-prune`'s retain raised from 1 to 7
to match, since Longhorn's delete task enforces its own count whatever the snapshot task asks for;
twelve-hourly etcd snapshots retaining five, to the control-plane node's local disk; and the horizon
operator and interface, the burst node modules, the Packer definition and the measurement harness,
dormant. Those last are provider-shaped rather than account-shaped, so with no ProviderConfig they
lease nothing and cost nothing while keeping work that is expensive to reconstruct.

The S3 coordinates are the single swap point when off-site backups return. Every removed writer
addressed its bucket through a bucket name, a region, an endpoint and one credential, because
[0009](0009-velero-backups.md) kept that configuration provider-neutral, so restoring them is a
matter of creating buckets and restoring four values rather than choosing an architecture again.

## Options considered

- Remove everything and accept the gap, chosen. It is the only option that leaves the repository
  describing what actually runs; the alternatives keep manifests, credentials or bills alive for a
  capability that is either absent or paid for twice.
- Repoint every writer at a different rented S3 provider. It preserves the off-site copy and is the
  strongest argument against this record. Rejected because it trades one standing bill for another to
  hold data meant to land on hardware already chosen, and because each of four cutovers is a moment a
  backup chain breaks silently, as the barman-cloud cutover already did once.
- Buy the NAS now and cut straight over. Deferred rather than rejected: it is the intended end state,
  but committing four figures of unplanned spend to preserve a mechanism that has never been
  restore-tested is the wrong order to do things in.
- Back up to a local disk on the control-plane node or the operator workstation. Rejected. It sits in
  the same building, so it answers none of the scenarios [0009](0009-velero-backups.md) was written
  for, and it is a hand-managed path outside the GitOps loop.
- Keep Velero alone against another bucket for the Secrets copy. Rejected, but it exposes the one
  thing genuinely lost: every Secret it captured is already SOPS ciphertext in `bedrock-secrets` bar
  the age key that opens that repository, and that escrow belongs in a password manager.

## Consequences

There is no off-site copy of anything. A fire, a theft or a flood now takes the cluster and every copy
of its data in one event, which is precisely the scenario [0009](0009-velero-backups.md) was written
for. This is accepted knowingly and is the largest consequence of this record.

Postgres loses point-in-time recovery, the largest single capability lost. Volume durability becomes
three-way replication plus a rolling week of nightly snapshots, which recovers an accidental deletion
that replication alone cannot and is still not a backup, because a snapshot rides the same volume and
replicas as the data it protects. Etcd snapshots survive only on the control-plane node's disk,
reinstating the coupling [0064](0064-off-node-etcd-s3-snapshots.md) was written to remove. Capacity is
the three home nodes until a ProviderConfig and a credential exist again, though
`longhorn-node-finalizer` stays, since it finalizes a stranded record whatever stranded it.

The removal has to reconcile before account access is revoked, and the order is not a preference. The
`hetzner` ProviderConfig carries a finalizer set by the running horizon operator, whose teardown
releases leases against the hcloud API before giving up ownership, so a dead credential at that
moment leaves the object in `Terminating` forever. The general form is worth carrying past this
change: an object with a controller-owned finalizer can only be torn down while its provider still
answers.

Nothing bills, leaving the domain and the Cloudflare and Tailscale accounts as the only standing
external costs. Records whose backup or burst premise died with the account are marked in place rather
than rewritten, with [0009](0009-velero-backups.md) the exception and fully superseded.

## Update 2026-09-12

Postgres's half of this record was reversed sooner than expected, and an audit along the way found
that the removal had left a defect: with `spec.backup` gone, the CNPG cluster's `LastBackupSucceeded`
and `ContinuousArchiving` conditions kept reading `True` for 43 days against a destination that had
already been closed. Nothing noticed, because the alert groups that watched Barman were removed with
Barman itself and no replacement checked the recovery point directly.

Base backups and the write-ahead-log stream now go to a `postgres` bucket on the in-cluster MinIO
instance, which already runs for the blog's object storage, under a 30 day retention policy with a
nightly `ScheduledBackup`, so point-in-time recovery inside that window is restored. This does not
reopen the decision above: MinIO sits on the same three nodes as everything it would protect, so one
event still takes every copy, and the NAS remains unbought. Two guardrails come with the repoint,
because the defect was a status field nobody was alerting on. `CNPGBackupStale` reads the newest base
backup CloudNativePG can actually recover from and fires once it is more than two days old, whatever
the cluster's own conditions report, and `CNPGBackupNotConfigured` fires if the metric carrying that
recovery point disappears entirely.

---
status: accepted
date: 2026-09-06
---

# 0081. Retire the Hetzner account and accept an estate with no off-site backups

## Context

The Hetzner Cloud account the estate has depended on since [0009](0009-velero-backups.md) is being
closed. That is an external event rather than a design choice, so the question this record settles is
not whether to leave Hetzner but what to do about the capabilities that leave with it.

Four mechanisms depended on the account. Velero wrote resource backups to `basalt-backups`
([0009](0009-velero-backups.md)). Longhorn's `backup` RecurringJob wrote volume backups to the same
bucket ([0005](0005-longhorn-storage.md)), and k3s uploaded its scheduled etcd snapshots there
([0064](0064-off-node-etcd-s3-snapshots.md)). CloudNativePG's Barman archiver wrote base backups and
a continuous write-ahead-log stream to a second bucket, `basalt-cnpg-backups`
([0057](0057-cnpg-barman-dr-and-velero-scope.md)). Separately, horizon leased servers through the
hcloud API to add capacity beyond the three home nodes
([0062](0062-retire-elastic-cluster-autoscaler.md), [0071](0071-deploy-horizon-operator-from-published-chart.md),
[0072](0072-burst-node-credential-blast-radius.md)).

Velero's actual contribution was smaller than [0009](0009-velero-backups.md) claims. Its `daily-dr`
schedule selected Secrets, PersistentVolumeClaims, PersistentVolumes and VolumeSnapshots.
`snapshotMoveData` was off and the cluster had recorded no `DataUpload` object at any point, so no
volume bytes ever left the cluster through Velero. What it put off-site was a copy of the estate's
Secrets and its claim-to-volume bindings. Volume durability rode Longhorn's own BackupTarget, which
is what the 2026-07-29 correction to [0057](0057-cnpg-barman-dr-and-velero-scope.md) had already
established.

The intended replacement is a NAS in the rack: TrueNAS SCALE on RAIDZ2, fronted by democratic-csi and
exposing S3-compatible storage to the cluster. It is chosen but not bought. With drives it comes to
roughly 1270 to 1700 EUR, it is deferred on cost, and no purchase has been made or dated. Treating it
as imminent would be planning around something that does not exist.

## Decision

Remove every mechanism that depended on the Hetzner account rather than repointing it at a substitute
provider, and run without an off-site copy until the NAS exists.

What goes: Velero in full, meaning the HelmRelease, the `daily-dr` schedule, the
`longhorn-snapshot-vsc` VolumeSnapshotClass, the volume policy, its network policies, the velero-ui
application and the namespace. The Longhorn BackupTarget and its `backup` RecurringJob. The
CloudNativePG barman-cloud plugin with its ObjectStore and ScheduledBackup, and the outbound 443 rule
that existed so the archiver could reach object storage. The k3s `--etcd-s3*` flags and the
`etcd-s3-credentials` agenix secret. Horizon's Hetzner ProviderConfig, the `cluster-horizon-provider`
Flux Kustomization and the hcloud API egress policy. The weekly Packer snapshot build. The alert
groups that watched all of it, since an alert on a component that no longer exists is noise. The
matching credentials are deleted from the private `bedrock-secrets` repository in the same pass
([0060](0060-private-secrets-repo-per-cluster-keys.md)).

What stays: everything that does not need object storage. Longhorn keeps three-way replication and
its `snapshot-prune` and `filesystem-trim` recurring jobs. K3s keeps
`--etcd-snapshot-schedule-cron` and `--etcd-snapshot-retention`, so etcd still snapshots twelve-hourly
and retains five, to master's local disk. The horizon operator, the horizon interface,
`modules/k3s/cluster-node.nix`, `modules/k3s/hetzner-scaffolding.nix`, `infra/packer/` and the burst
measurement harness all remain in the repository, dormant. They are provider-shaped rather than
account-shaped: with no `ProviderConfig` they lease nothing and cost nothing, and they carry the
measurement work from [0076](0076-burst-measurement-injection-in-monitoring.md) and
[0077](0077-run-the-m4-policy-arms-concurrently.md), which is expensive to reconstruct and cheap to
keep.

The S3 coordinates are the single swap point when off-site backups return. Every removed writer
addressed its bucket the same way, through a bucket name, a region, an endpoint and one credential,
because [0009](0009-velero-backups.md) kept that configuration provider-neutral on purpose. Restoring
off-site backups against the NAS is therefore a matter of creating the buckets, restoring those four
values and re-adding the credential, not of choosing a backup architecture again. The removed
manifests stay recoverable from history rather than needing to be rewritten.

## Options considered

- Remove everything and accept the gap, chosen. It is the only option that leaves the repository
  describing what actually runs. The alternative shapes all keep manifests, credentials or bills alive
  for a capability that is either absent or paid for twice.
- Repoint every writer at a different rented S3 provider. It preserves the off-site copy, which is the
  capability genuinely worth having, and it is the strongest argument against this record. Rejected
  because it trades one standing monthly bill for another to hold data that is meant to land on
  hardware already chosen, and because it means cutting four writers over twice rather than once. The
  barman-cloud cutover alone broke write-ahead-log archiving once already, and each cutover is the
  moment a backup chain is most likely to break silently.
- Buy the NAS now and cut straight over to it. Deferred rather than rejected: it is the intended end
  state. Nothing has been purchased, and committing four figures of unplanned spend to preserve
  continuity of a backup mechanism that has never once been restore-tested is the wrong order to do
  things in.
- Back up to a local disk on master or on the operator workstation. Rejected. It would sit in the same
  building as the cluster, so it answers none of the fire, theft and flood scenarios
  [0009](0009-velero-backups.md) was written for, and it would be a hand-managed path outside the
  GitOps loop, which is the shape of infrastructure this repository exists to avoid.
- Keep Velero alone, pointed at some other bucket, for the Secrets copy. Rejected, but it exposes the
  one thing genuinely lost with Velero. Every Secret it captured is already held as SOPS ciphertext in
  `bedrock-secrets`, with one exception: `flux-system/sops-age`, the key that opens that repository
  and which neither repository can hold by definition. Velero was an accidental escrow for it. That
  escrow belongs in a password manager, not in a backup system, and running a backup stack to obtain
  it by side effect was never the right mechanism.

## Consequences

There is no off-site copy of anything. A fire, a theft or a flood now takes the cluster and every copy
of its data in one event, which is precisely the scenario [0009](0009-velero-backups.md) was written
for and the one nothing else in the estate addresses. This is accepted knowingly, and it is the
largest consequence of this record.

Postgres loses point-in-time recovery, which is the largest single capability lost. Barman could
replay the database to any moment inside a 30 day window. Nothing replaces it. Longhorn replication
protects the bytes on disk, but a replicated write is still a write: a logical fault, a bad migration
or a deletion reaches all three replicas at once and is no longer recoverable at all. No recovery
point for Postgres is stated anywhere any more, because there is none to state.

No recurring job creates Longhorn snapshots any longer. The `backup` job was the only one that did,
since Longhorn's backup task snapshots a volume before uploading it; `snapshot-prune` deletes
snapshots and `filesystem-trim` reclaims space. Volume durability is now three-way replication alone,
which survives a disk failure or a node failure and nothing else. Restoring a scheduled snapshot job
is a small change that costs local capacity rather than an account, and it should be weighed on its
own merits rather than inherited from this record.

Etcd snapshots survive but only on master's disk, which reinstates exactly the coupling
[0064](0064-off-node-etcd-s3-snapshots.md) was written to remove: the datastore and every snapshot
that could rebuild it sit on one disk, and one failure takes both.

Capacity is the three home nodes. Nothing bursts, and nothing can burst until a `ProviderConfig` and a
credential for some provider exist again. The alerting, the taints and the reaper that surround burst
nodes are all still declared, so they will resume behaving as recorded whenever that happens rather
than needing to be rediscovered.

The removal has to reach the cluster and reconcile before the Hetzner account access is revoked, and
the order is not a preference. The `hetzner` ProviderConfig carries the finalizer
`horizon.dev/provider-config`, set by the running horizon operator rather than by anything in the
repository. Flux prunes the object when this change lands, but Kubernetes holds it in `Terminating`
until the operator clears that finalizer, and the operator's teardown path releases leases against the
hcloud API before it gives up ownership ([0071](0071-deploy-horizon-operator-from-published-chart.md)).
A dead credential at that moment means the finalizer never clears and the object hangs forever, which
recreates through a different mechanism the stuck state this record exists to remove. The general form
is worth carrying past this change: an object with a controller-owned finalizer can only be torn down
while its provider still answers.

Nothing bills. The estate's only remaining standing external costs are the domain and the accounts
behind Cloudflare and Tailscale.

The records whose backup or burst premise died with the account are marked in place rather than
rewritten, following the convention the log already uses: a partial status on the index entry and the
front matter, and a dated correction at the foot of the record saying which sentences no longer hold.
[0009](0009-velero-backups.md) is the exception and is fully superseded, because nothing of its
decision survives.

Reversing this record means creating two buckets on whatever storage exists then, restoring the S3
coordinate groups and their credentials, and deciding afresh whether Velero is worth reinstating given
that it moved no volume bytes. The Postgres half is the part worth restoring first.

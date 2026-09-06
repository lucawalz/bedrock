---
status: superseded by 0081
date: 2026-04-26
---

# 0009. Back up the cluster with Velero to Hetzner object storage

> Superseded by [0081](0081-retire-the-hetzner-account.md).

## Context

The cluster runs at home, on one internet line, in one building. A disk failure is one thing, but a fire, a theft, or a flooded basement takes the whole estate at once. Recovery from that needs a copy of the cluster's resources and volumes somewhere off-site. The backups also have to be scoped per namespace, because the companion horizon controller migrates a workload by backing up its namespace and restoring it onto a burst node.

## Decision

Velero handles cluster backup and restore, targeting an S3-compatible object storage bucket through the AWS S3 plugin, configured in `infrastructure/storage/velero/`. The configuration is provider-neutral: `provider: aws` with `s3ForcePathStyle` and a custom endpoint, so the bucket can live on any S3-compatible provider. The bucket name, region, and endpoint are a single `objectStorage` coordinate group in the HelmRelease values, and the access keys live in a SOPS-encrypted secret that Flux owns and applies. A daily schedule runs disaster-recovery backups with a one-week retention, and Velero captures both resource manifests and CSI volume snapshots, so a restore brings back the workloads and their data, not just the YAML.

The bucket itself is created once, out-of-band, in the same spirit as the cluster age key. No destroy-capable tooling runs against the object-storage provider from this repository, because that account is shared with the separate vigil project.

## Options considered

- Velero to Hetzner object storage, chosen. Off-site, off the home line, with namespace-scoped backups that double as the migration primitive horizon relies on.
- Longhorn-native backups alone. They protect volume data at the storage layer from [0005](0005-longhorn-storage.md), but they do not capture the Kubernetes resource manifests, so they cannot rebuild a namespace on their own.
- Hand-rolled restic. Maximum control, but it would reimplement scheduling, retention, and Kubernetes-aware restore that Velero already provides.

## Consequences

The cluster can be rebuilt from off-site copies, and namespace backups give horizon a clean way to move a workload to the cloud. The cost is another dependency on a SOPS-encrypted credential, the S3 access keys, and the usual backup discipline: a backup that is never restore-tested is a guess, so restores have to be exercised, not assumed.

**Correction, 2026-09-06.** The Hetzner account this record depends on is closed and Velero is removed in full by [0081](0081-retire-the-hetzner-account.md). Two claims should not be carried forward. The Decision's "Velero captures both resource manifests and CSI volume snapshots, so a restore brings back the workloads and their data, not just the YAML" was never true of this estate as configured: `snapshotMoveData` was off and no `DataUpload` object was ever recorded, so no volume bytes left the cluster through Velero. Its off-site contribution was the estate's Secrets and its claim-to-volume bindings. And the namespace-scoped backups the Context justifies as horizon's migration primitive were never used that way; horizon migrates through provisioning rather than through restore. What does survive is the provider-neutral shape of the configuration, which is why [0081](0081-retire-the-hetzner-account.md) treats the S3 coordinates as the single swap point when off-site backups return.

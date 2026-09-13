---
status: superseded by 0081
date: 2026-04-26
---

# 0009. Back up the cluster with Velero to Hetzner object storage

## Context

The cluster runs at home, on one internet line, in one building. A disk failure is one thing, but a fire, a theft, or a flooded basement takes the whole estate at once. Recovery from that needs a copy of the cluster's resources and volumes somewhere off-site. The backups were also meant to be scoped per namespace, on the reasoning that the companion horizon controller would migrate a workload by backing up its namespace and restoring it onto a burst node.

## Decision

Velero handled cluster backup and restore against an S3-compatible bucket through the AWS S3 plugin. The configuration was deliberately provider-neutral, `provider: aws` with `s3ForcePathStyle` and a custom endpoint, and the bucket name, region, and endpoint sat together as a single `objectStorage` coordinate group in the HelmRelease values, with the access keys in a SOPS-encrypted secret that Flux owned. A daily schedule ran disaster-recovery backups with a one-week retention. The bucket itself was created once, out-of-band, in the same spirit as the cluster age key, and no destroy-capable tooling ran against the object-storage provider from this repository, because that account was shared with the separate vigil project.

## Options considered

- Velero to Hetzner object storage, chosen. Off-site, off the home line, with namespace-scoped backups.
- Longhorn-native backups alone. They protect volume data at the storage layer from [0005](0005-longhorn-storage.md), but they do not capture the Kubernetes resource manifests, so they cannot rebuild a namespace on their own.
- Hand-rolled restic. Maximum control, but it would reimplement scheduling, retention, and Kubernetes-aware restore that Velero already provides.

## Consequences

Two claims made here were withdrawn when [0081](0081-retire-the-hetzner-account.md) closed the account and removed Velero in full. Velero never captured volume data in this estate: `snapshotMoveData` was off and no `DataUpload` object was ever recorded, so its off-site contribution was the Secrets and the claim-to-volume bindings rather than volume bytes. The namespace-scoped backups were never used as horizon's migration primitive either, because horizon migrates through provisioning rather than through restore. What survives is the provider-neutral shape of the configuration, which is why [0081](0081-retire-the-hetzner-account.md) treats the S3 coordinates as the single swap point when off-site backups return. The cluster has had no off-site copy since.

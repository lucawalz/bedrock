---
status: accepted
date: 2026-04-26
---

# 0009. Back up the cluster with Velero to Hetzner object storage

## Context

The cluster runs at home, on one internet line, in one building. A disk failure is one thing, but a fire, a theft, or a flooded basement takes the whole estate at once. Recovery from that needs a copy of the cluster's resources and volumes somewhere off-site. The backups also have to be scoped per namespace, because the companion horizon controller migrates a workload by backing up its namespace and restoring it onto a burst node.

## Decision

Velero handles cluster backup and restore, targeting Hetzner object storage in `fsn1` through the AWS S3 plugin, configured in `infrastructure/storage/velero/`. A daily schedule runs disaster-recovery backups with a one-week retention, and Velero captures both resource manifests and CSI volume snapshots, so a restore brings back the workloads and their data, not just the YAML.

## Options considered

- Velero to Hetzner object storage, chosen. Off-site, off the home line, with namespace-scoped backups that double as the migration primitive horizon relies on.
- Longhorn-native backups alone. They protect volume data at the storage layer from [0005](0005-longhorn-storage.md), but they do not capture the Kubernetes resource manifests, so they cannot rebuild a namespace on their own.
- Hand-rolled restic. Maximum control, but it would reimplement scheduling, retention, and Kubernetes-aware restore that Velero already provides.

## Consequences

The cluster can be rebuilt from off-site copies, and namespace backups give horizon a clean way to move a workload to the cloud. The cost is another dependency on a SOPS-encrypted credential, the Hetzner S3 access keys, and the usual backup discipline: a backup that is never restore-tested is a guess, so restores have to be exercised, not assumed.

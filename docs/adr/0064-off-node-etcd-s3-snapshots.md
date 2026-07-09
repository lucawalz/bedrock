---
status: accepted
date: 2026-07-09
---

# 0064. Off-node etcd S3 snapshots for the single-node control plane

## Context

The cluster runs a single control-plane node on master with embedded etcd. K3s takes scheduled etcd snapshots, but by default it writes them only to master's local disk under the data directory. That leaves the datastore and its backups on the same disk: a disk failure on master loses etcd and every snapshot that could rebuild it at the same moment. The accepted single-control-plane trade-off from [0053](0053-ha-critical-path-survives-node-loss.md) tolerates the loss of any one node for the workload path, but it says nothing about recovering the datastore itself, and a lost etcd is a lost cluster.

## Decision

Enable k3s scheduled etcd snapshots and upload them to the existing basalt-backups Hetzner Object Storage bucket. K3s runs on a twelve-hour cadence and retains the five most recent snapshots, writing them to the etcd-snapshots folder of the bucket at endpoint hel1.your-objectstorage.com in region eu-central-1. The S3 access keys reach the host through agenix as a systemd EnvironmentFile on the k3s service, following the host-secret split from [0007](0007-agenix-sops-secrets.md); the encrypted etcd-s3-credentials.age is decrypted at boot and never lives in the repository in plaintext.

The bucket already exists and is created out-of-band, in the same spirit as the Velero object storage from [0009](0009-velero-backups.md). No destroy-capable tooling runs against the object-storage provider from this repository.

## Options considered

- Off-node etcd snapshots to Hetzner Object Storage, chosen. Snapshots survive the loss of master's disk and sit alongside the existing off-site backups.
- Local-disk snapshots only, the k3s default. Rejected, because the snapshot and the datastore share one disk and one failure takes both.
- A second etcd member for high availability. Out of scope. This record is disaster recovery for the accepted single-control-plane topology, not a move to a multi-member control plane.

## Consequences

The accepted single-control-plane single point of failure becomes recoverable: a rebuilt master can restore etcd from the most recent off-node snapshot. This is disaster recovery, not high availability, and it does not change the control-plane topology. Etcd snapshots now share the same S3 provider as the Longhorn volume backups from [0005](0005-longhorn-storage.md) and the Velero cluster backups from [0009](0009-velero-backups.md), which concentrates recovery on one provider account and adds one more agenix-managed host credential to keep current.

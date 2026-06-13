---
status: accepted
date: 2025-11-02
---

# 0005. Use Longhorn for replicated block storage

## Context

Workloads on the cluster need persistent storage that survives a node going down. With three nodes and commodity disks, the storage layer has to replicate volumes across machines, support snapshots, and be managed from inside the cluster rather than depending on an external SAN or NAS. It also has to be light enough that it does not eat the modest hardware it runs on.

## Decision

Storage is Longhorn, installed through Flux from a Helm chart with a default replica count of three, so every volume has a copy on each node and the loss of one node does not lose data. Longhorn is the default StorageClass, manages its disks on each node, and provides the snapshots that Velero backs up off-site.

## Options considered

- Longhorn, chosen. Cluster-native replicated block storage with snapshots and a default replica count of 3, run as a Helm release and operated through its own UI.
- Rook/Ceph. More powerful and more flexible, but far heavier: Ceph expects more nodes and more resources than three mini PCs can spare, and its operational complexity is a poor fit for a homelab.
- local-path. Trivial and fast, but it pins a volume to one node with no replication, so any node failure takes its data with it. K3s ships it as local-storage, which this cluster disables.
- OpenEBS. A reasonable middle ground, but Longhorn's snapshot and backup integration was the better match for the disaster-recovery story.

## Consequences

Volumes survive a node failure and can be snapshotted and restored. The cost is replication overhead: three copies of every volume use disk and network, and Longhorn needs some tuning to behave well on small hardware. Longhorn is the source layer that the off-site backups in [0009](0009-velero-backups.md) protect.

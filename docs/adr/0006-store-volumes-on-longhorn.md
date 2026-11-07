---
status: accepted
date: 2026-11-07
---

# 0006. Store volumes on Longhorn

## Context

Stateful workloads need volumes that survive the loss of one node, and the three nodes have only local disks. Some data deserves snapshots and off-site backups, while some is a cache that is cheaper to refetch than to keep. Paperless holds scanned personal documents, and its backups leave the house.

## Decision

- Longhorn provides block storage on every node. The default class `longhorn` and `longhorn-retain` keep three replicas with hard anti-affinity, and `longhorn-disposable` keeps one for data that can be refetched. Thin provisioning allows up to 200 percent over-provisioning.
- Recurring jobs are opted into per volume through labels, never by default. The `snapshot` job runs nightly and keeps seven; `offsite-backup` runs at 05:00 to the `bedrock-longhorn` bucket in R2 and keeps fourteen. `scripts/check-snapshot-coverage.sh` requires every Longhorn volume to declare its jobs explicitly. Ollama models and the zot cache take neither snapshots nor backups.
- The Paperless and Open WebUI volumes use `longhorn-encrypted`, which formats them with LUKS through the CSI plugin, so their R2 backups are ciphertext. One global key in the `longhorn-crypto` Secret serves every encrypted volume, and the key derivation is pbkdf2. The key is random, so a memory-hard derivation adds no security, while its memory is spent inside the CSI plugin on every format and unlock; four concurrent argon2id formats exceeded the plugin's limit and corrupted the headers.
- The NixOS hosts supply what Longhorn expects of a host: open-iscsi, the `dm_crypt` module, cryptsetup, and `/usr/local/bin` ([0002](0002-declare-every-host-with-nixos-flakes.md)).

## Consequences

- Any one node can be lost without losing data on a three-replica volume.
- Losing the `longhorn-crypto` key makes every encrypted volume and backup unreadable, so the key is held offline ([0004](0004-keep-a-stable-cluster-ca-under-an-offline-root.md)).
- Thin provisioning lets declared sizes exceed the disks. `LonghornVolumeOverDeclared` records that as an info alert, which routes to the null receiver because it asks for no action; the scheduling headroom alerts are the ones that page.

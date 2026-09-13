---
status: accepted, implemented
date: 2026-07-29
---

# 0069. Record the Longhorn prerequisites that NixOS does not provide

## Context

Longhorn is written for a conventional Linux distribution. It assumes an iSCSI initiator is installed and running, that host binaries can be reached under `/usr/local/bin`, that the NFS client is present for ReadWriteMany volumes, and that the kernel modules it probes for are loaded. NixOS provides none of these by default, so each had to be supplied explicitly in `modules/services/storage.nix`, and each was found the hard way. Nothing recorded why any of it exists: [0005](0005-longhorn-storage.md) chose Longhorn but never mentions iSCSI, kernel modules or the symlink, so a nixpkgs bump that touches any of them presents as a Longhorn fault with no trail back to the host layer. That happened twice in July 2026 and cost about fourteen hours the first time.

## Decision

Record the four prerequisites, what each is for, and how each fails when absent.

- `services.openiscsi`, enabled with a per-host initiator name of the form `iqn.2016-04.com.open-iscsi:${meta.hostname}`. Longhorn attaches every volume over iSCSI to the node running the workload, so without `iscsid` no volume attaches anywhere and the node looks healthy while every pod that needs storage hangs in `ContainerCreating`.
- `boot.kernelModules` carrying `dm_crypt`. Nothing else on these hosts pulls it in, and without it Longhorn reports `KernelModulesLoaded=false` on the node. That condition is advisory and sat on all three nodes for a long period without causing an incident, so it is not a cause to read into misbehaving storage.
- A `systemd.tmpfiles` rule linking `/usr/local/bin` to `/run/current-system/sw/bin/`. Longhorn's node scripts invoke host binaries through that FHS path, which does not exist on NixOS.
- `nfs-utils`, installed through `hosts/common/packages.nix` rather than this module, because ReadWriteMany volumes are served by a share manager that needs the NFS client on whichever node mounts them.

One further failure belongs here, because it lives in the host layer even though it presents as a storage fault. An open-iscsi version change invalidates the persisted node records under `/etc/iscsi/nodes` in both directions, and a single invalid file aborts the whole directory read, so one stale record from a departed portal disables every `iscsiadm` call on that node, Longhorn engines fail to start their iSCSI frontend, and volumes cycle between attaching and faulted. Upgrading a host across such a change means purging `/etc/iscsi/nodes` and `/etc/iscsi/send_targets` in the same operation as the reboot, so nothing rewrites the records in between.

## Options considered

- Record the prerequisites in an ADR, chosen. The configuration is small, but every line of it is load-bearing and none of it is obvious, and rediscovering any one line costs hours of debugging aimed at Longhorn when the fault is in the host.
- Rely on comments in `modules/services/storage.nix`. Rejected. The file already carries brief comments and they were not enough: they say what each line does, not what breaks without it, and they cannot hold the open-iscsi upgrade hazard, which spans the host layer and the storage layer and belongs in neither file alone.
- Extend [0005](0005-longhorn-storage.md). Rejected. That record decides which storage system to run; what the host must provide to run it is a separate decision, and the ADR log does not rewrite accepted records.

## Consequences

A storage failure after a nixpkgs bump now has a documented first place to look, and the open-iscsi hazard is written down ahead of the next channel bump. The prerequisites are also duplicated: `modules/k3s/cluster-node.nix`, the dormant burst-node role, repeats the `openiscsi` block and the `/usr/local/bin` symlink word for word but omits `dm_crypt`. The divergence is harmless, since the missing condition is advisory, but the duplication means any future change to these prerequisites has to be made in two files with nothing enforcing it. Consolidating them into one imported module is the obvious follow-up, left undone so that this record describes the estate as it stands.

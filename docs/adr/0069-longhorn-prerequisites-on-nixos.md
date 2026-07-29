---
status: accepted, implemented
date: 2026-07-29
---

# 0069. Record the Longhorn prerequisites that NixOS does not provide

## Context

Longhorn is written for a conventional Linux distribution. It assumes an iSCSI initiator is installed and running, that host binaries can be reached under `/usr/local/bin`, that the NFS client is present for ReadWriteMany volumes, and that the kernel modules it probes for are loaded. NixOS provides none of these by default, so each one had to be supplied explicitly, and each was discovered by a failure rather than by reading documentation.

The resulting configuration lives in `modules/services/storage.nix` and is seventeen lines long. Nothing recorded why any of it exists. [0005](0005-longhorn-storage.md) chose Longhorn but is twenty-five lines and mentions neither iSCSI, kernel modules, nor the symlink. The consequence is that a nixpkgs bump touching any of these presents as a Longhorn fault with no trail back to the host layer, which is exactly what happened twice in July 2026 and cost roughly fourteen hours the first time.

## Decision

Record the four prerequisites, what each is for, and how each fails when absent.

`services.openiscsi` is enabled with a per-host initiator name of the form `iqn.2016-04.com.open-iscsi:${meta.hostname}`. Longhorn attaches every volume over iSCSI to the node running the workload, so without `iscsid` no volume attaches anywhere and the node appears healthy while every pod that needs storage hangs in `ContainerCreating`.

`boot.kernelModules` carries `dm_crypt`. Nothing else on these hosts pulls it in, and without it Longhorn reports `KernelModulesLoaded=false` on the node. That condition is advisory rather than fatal, and it was present on all three nodes for a long period without causing any incident, so it should not be read as a cause when storage misbehaves.

A `systemd.tmpfiles` rule links `/usr/local/bin` to `/run/current-system/sw/bin/`. Longhorn's node scripts invoke host binaries through that FHS path, which does not exist on NixOS.

`nfs-utils` is installed through `hosts/common/packages.nix` rather than this module, because ReadWriteMany volumes are served by a share manager that requires the NFS client on the node mounting them.

Record alongside these the failure mode most likely to recur, because it is a property of the host layer rather than of Longhorn. An open-iscsi version change invalidates the persisted node records under `/etc/iscsi/nodes` in both directions. Version 2.1.11 writes `node.session.conn_reopen_log_freq` and 2.1.12 writes `node.session.sess_reopen_log_freq`, and each rejects the other's records. A single invalid file aborts the whole directory read, so one stale record from a departed portal disables every `iscsiadm` call on that node. Longhorn engines then fail to start their iSCSI frontend, volumes cycle between attaching and faulted roughly every fifteen seconds, and every pod reports that its volume has not been attached yet. Upgrading a host across such a change therefore requires purging `/etc/iscsi/nodes` and `/etc/iscsi/send_targets` in the same operation as the reboot, so nothing rewrites records in between.

## Options considered

- Record the prerequisites in an ADR, chosen. The configuration is small but every line of it is load-bearing and non-obvious, and the cost of rediscovering any of it is measured in hours of misdirected debugging against Longhorn rather than against the host.
- Rely on comments in `modules/services/storage.nix`. Rejected. The file already carries brief comments and they were not enough: they say what each line does, not what breaks without it, and they cannot record the open-iscsi upgrade hazard, which spans the host layer and the storage layer and belongs in neither file alone.
- Extend [0005](0005-longhorn-storage.md) instead of writing a new record. Rejected. That record decides which storage system to run, which is a separate decision from what the host must provide to run it, and the ADR log does not rewrite accepted records.

## Consequences

A storage failure after a nixpkgs bump now has a documented first place to look, and the open-iscsi hazard is written down before the next channel bump rather than after it.

The prerequisites are duplicated rather than shared. `modules/k3s/cluster-node.nix`, the role used for on-demand Hetzner agents, repeats the `openiscsi` block and the `/usr/local/bin` symlink verbatim but omits `dm_crypt`, so a burst node is configured differently from a home node for no recorded reason. The divergence is harmless today, because the missing condition is advisory, but the duplication means any future change to these prerequisites has to be made in two files and nothing enforces that it is. Consolidating them into one imported module is the obvious follow-up and is deliberately not done here, so that this record documents the estate as it stands rather than describing a refactor that has not happened.

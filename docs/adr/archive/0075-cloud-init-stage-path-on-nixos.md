---
status: accepted, burst premise superseded by 0081
date: 2026-08-06
---

# 0075. Prepend curl and GNU coreutils to the cloud-init stage PATH ahead of busybox

## Context

Burst nodes boot from a NixOS snapshot ([0073](0073-generic-burst-node-image.md)), and their cloud-init user data downloads and installs the horizon watchdog binary. On 6 August 2026 that install never ran, and the node looked healthy while the watchdog had never armed. The immediate cause was that `cloud-final.service` on NixOS runs with an explicit PATH that excludes `/run/current-system/sw/bin`, so `curl` was not found.

The audit that followed found a larger problem underneath. Busybox precedes coreutils on that PATH, because the upstream NixOS cloud-init module assigns the stage units' `path` option itself as a plain, unprioritised list containing busybox. Nine of the eleven tools that did resolve were served by busybox applets rather than the real ones, including `sha256sum`, `install`, `mktemp` and `cat`, while `tar`, `awk` and gzip decompression had no GNU alternative on the PATH at all. `curl` was simply the first tool busybox cannot satisfy, which is why the boot died exactly there, and the same defect mattered for the checksum verification shipped the same day, whose `awk` selector would have run under busybox awk and diverges from gawk and mawk on CRLF handling.

## Decision

Prepend `curl`, `gnutar`, `gzip`, `gawk` and `coreutils` to the PATH of all four cloud-init stage units, `cloud-init-local`, `cloud-init`, `cloud-config` and `cloud-final`, with `systemd.services.<unit>.path = lib.mkBefore [ ... ]`.

NixOS merges a `listOf` option's definitions sorted by priority before concatenating them. `lib.mkBefore` is priority 500, an unwrapped definition is 1000, and `lib.mkAfter` is 1500, so each stage unit's `path` resolves as the five prepended tools, then the cloud-init module's own list carrying busybox, then the NixOS default additions. `nixos/lib/systemd-lib.nix` builds `environment.PATH` by walking that merged list in order, with no deduplication and no reordering, so the first entry for a given executable name wins and the five tools land ahead of busybox on all four units.

## Options considered

- Prepend the five tools with `lib.mkBefore` on each stage unit, chosen. It is the only mechanism that lands ahead of busybox in the merged list, and it fixes the shadowed coreutils along with the missing `curl`.
- `services.cloud-init.extraPackages`. Rejected. It appends after busybox, so `curl` would resolve correctly while the busybox applets still shadowed the real coreutils.
- `environment.systemPackages`. Rejected. It never reaches a systemd unit's own PATH, only the interactive shell's.
- Absolute Nix store paths inside the horizon-rendered user data. Rejected. Horizon has zero coupling to this estate deliberately, and that document must stay image-agnostic, which a baked store path breaks on the first store path change.

## Consequences

Verified on a live burst node on 6 August 2026: `cloud-final`'s PATH carries the five tools ahead of busybox, every tool the installer invokes resolves to the real binary rather than an applet, the watchdog armed, and `systemctl is-active horizon-watchdog` reported active for the first time on the custom image path.

`cloud-final` completing restores a premise both [0073](0073-generic-burst-node-image.md) and [0074](0074-home-nodes-on-the-tailnet.md) depend on without stating it: 0073 relies on it when dropping the tailscale authkey wait loop, and 0074 relies on it when ordering `tailscaled-autoconnect` after `cloud-final`. This record does not supersede either; it repairs a premise both already assumed held, and both stay accepted in the index. The change touches `cluster-node.nix`, so the snapshot hash moves with it and a rebuild plus promotion is required before any node receives it.

A residual limitation is worth recording rather than hiding: `grep` and `sed` still resolve to busybox, because `gnugrep` and `gnused` sit at the default `lib.mkAfter` priority behind busybox's. That is harmless while the generated installer invokes neither, and a trap if it ever grows one. The whole path is dormant in any case, because [0081](0081-retire-the-hetzner-account.md) closed the account and removed the `ProviderConfig`, so nothing leases a node to run cloud-init on until a provider exists again.

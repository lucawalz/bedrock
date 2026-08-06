---
status: accepted
date: 2026-08-06
---

# 0075. Prepend curl and GNU coreutils to the cloud-init stage PATH ahead of busybox

## Context

Burst nodes boot from a NixOS snapshot ([0073](0073-generic-burst-node-image.md)). Their cloud-init user data downloads and installs the horizon watchdog binary. On 6 August 2026 that install never ran, and the node looked healthy while the watchdog had never armed.

The immediate cause was that `cloud-final.service` on NixOS runs with an explicit PATH that excludes `/run/current-system/sw/bin`, so `curl` was not found. The audit that followed found a larger problem underneath: busybox precedes coreutils on that PATH, because the upstream NixOS cloud-init module assigns the stage units' `path` option itself as a plain, unprioritised list containing busybox. Nine of the eleven tools that did resolve were served by busybox applets rather than the real ones, including `sha256sum`, `install`, `mktemp`, and `cat`, while `tar`, `awk`, and gzip decompression had no GNU alternative on the PATH at all. `curl` was simply the first tool busybox cannot satisfy, which is why the boot died exactly there.

The same defect mattered for the checksum verification shipped the same day: its `awk` selector would have run under busybox awk, which diverges from gawk and mawk on CRLF handling.

## Decision

Prepend `curl`, `gnutar`, `gzip`, `gawk`, and `coreutils` to the PATH of all four cloud-init stage units, `cloud-init-local`, `cloud-init`, `cloud-config`, and `cloud-final`, with `systemd.services.<unit>.path = lib.mkBefore [ ... ]`.

### Why this mechanism and not the obvious ones

`services.cloud-init.extraPackages` was the first option considered and the one a reader will reach for. It appends after busybox rather than before it, so it would have put a real `curl` on the PATH but could never unshadow coreutils; the nine busybox applets would still have won every lookup ahead of it.

`environment.systemPackages` never reaches a unit's own PATH at all; it populates the interactive shell environment, not the sandboxed PATH systemd builds for a service.

Writing absolute Nix store paths into the user data itself was rejected on a different ground: horizon renders that document, and it has zero coupling to this estate today, deliberately. Baking a store path into it would tie horizon's cloud-init to a specific NixOS closure and break the image-agnostic property that coupling was kept out for.

### Why the ordering works

NixOS merges a `listOf` option's definitions sorted by priority before concatenating them. `lib.mkBefore` is priority 500, an unwrapped definition is 1000, and `lib.mkAfter` is 1500. Each stage unit's `path` therefore resolves as: the five prepended tools at 500, then the cloud-init module's own list, which carries busybox, at 1000, then the NixOS default additions at 1500. `nixos/lib/systemd-lib.nix` builds `environment.PATH` by walking that merged list in order, with no deduplication and no reordering, so the first entry for a given executable name wins and the five tools land ahead of busybox on all four units.

## Options considered

- `services.cloud-init.extraPackages`. Rejected: it appends after busybox in the merged `path`, so `curl` would resolve correctly but the busybox coreutils applets would still shadow the real ones.
- `environment.systemPackages`. Rejected: it never reaches a systemd unit's own PATH, only the interactive shell's.
- Absolute Nix store paths inside the horizon-rendered user data. Rejected: horizon has zero coupling to this estate, and that document must stay image-agnostic; hardcoding a store path breaks that on the first store path change.

## Consequences

Verified on a live burst node on 6 August 2026: `cloud-final`'s PATH carries curl, gnutar, gzip, gawk, and coreutils at positions 1 through 5 and busybox at position 12, and every tool the installer invokes resolves to the real binary rather than a busybox applet. The watchdog armed, and `systemctl is-active horizon-watchdog` reported active for the first time on the custom image path.

`cloud-final` completing restores a premise both [0073](0073-generic-burst-node-image.md) and [0074](0074-home-nodes-on-the-tailnet.md) depend on without stating it: 0073 relies on it when dropping the tailscale authkey wait loop, and 0074 relies on it when ordering `tailscaled-autoconnect` after `cloud-final`. This record does not supersede either; it repairs a premise both already assumed held, following the convention 0073 sets on 0041 and 0069 sets on the same accepted log, of noting the discrepancy in the new record rather than rewriting the old ones. 0073 and 0074 stay accepted in the index.

`scripts/nixos-image-hash.sh` already covers `cluster-node.nix`, so the snapshot hash moves with this change, from `294b5ee0` to `d1b57ec1`, and a rebuild plus promotion is required before any burst node receives it.

A residual limitation is worth recording rather than hiding: `grep` and `sed` still resolve to busybox, because `gnugrep` and `gnused` sit at the default `lib.mkAfter` priority of 1500, behind busybox's 1000. That is harmless today, since the generated installer invokes neither, and a trap if it ever grows one.

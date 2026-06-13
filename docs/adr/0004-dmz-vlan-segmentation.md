---
status: accepted
date: 2026-06-12
---

# 0004. Isolate the cluster on a VLAN 20 DMZ

## Context

Once the cluster was meant to face the public internet, it could no longer sit on the same flat network as personal machines. A service exposed to the outside that gets compromised should not reach a laptop or a NAS by default. That requires a real boundary between the cluster and the home LAN, enforced at the router rather than trusted by convention.

## Decision

The cluster nodes live on an isolated VLAN 20, with the router as its inter-zone gateway. The router forwards between the cluster zone and the internet but drops traffic from the cluster into the home subnet, so the blast radius of a compromised workload stops at the VLAN boundary. This builds on the NixOS router from [0003](0003-nixos-router-over-opnsense.md): the segmentation is an nftables forward rule in `modules/router/firewall.nix`, with addressing in `network.nix` and reservations in `dhcp.nix`.

VLAN 20 is now the trusted servers and cluster zone, addressed `10.20.0.0/24` with the router on `10.20.0.1`, and a separate VLAN 30 holds a true DMZ for any genuinely public-facing host. The cluster was originally numbered `192.168.20.0/24`; the concrete zoned addressing that replaces it, and the split of this single VLAN into a trusted zone and a real DMZ, are recorded in [0016](0016-concrete-zoned-ip-scheme.md), which supersedes the addressing in this record.

## Options considered

- An isolated VLAN 20, chosen. The cluster gets its own broadcast domain, and a forward rule keeps it from reaching the LAN.
- A flat LAN. Simpler, with no VLAN tagging or inter-network rules to maintain, but it offers no isolation and rules out exposing anything publicly without putting the rest of the house at risk.

## Consequences

The cluster is contained: a breach in a public service cannot pivot into personal devices without crossing a rule that denies it. The cost is that the cluster zone depends on the layer-3 router, and reaching it from the home LAN needs a static route to the cluster subnet via the Pi rather than just working. That extra hop is the price of the boundary. The original decision to isolate the cluster on its own VLAN stands; only the addressing and the introduction of a second DMZ zone have moved on, as captured in [0016](0016-concrete-zoned-ip-scheme.md).

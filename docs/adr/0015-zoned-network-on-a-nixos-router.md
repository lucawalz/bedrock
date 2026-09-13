---
status: superseded by 0016
date: 2026-06-13
---

# 0015. Keep the router on NixOS and move toward a zoned network model

## Context

The homelab network had grown organically. The router was a Raspberry Pi running NixOS, wired router-on-a-stick behind a Telekom Speedport that held the WAN, with a TP-Link TL-SG108E carrying the tags at layer 2. VLAN 20 was a DMZ on `192.168.20.0/24` holding the entire K3s cluster, the home LAN sat on `192.168.2.0/24`, a WireGuard hub served `10.100.0.0/24`, and AdGuard on the router answered split-horizon DNS for `syslabs.dev`.

That single VLAN conflated two trust levels. It was both the trusted production network for admin surfaces and the origin for the public-facing services the Cloudflare tunnel fronted, with no network-layer boundary between them; isolation rested entirely on Cloudflare Access and per-app authentication, as recorded in [0014](0014-declarative-minimal-cloudflare-exposure.md). A move to a dedicated OPNsense firewall appliance had been floated, which was worth a deliberate decision rather than a drift. [0003](0003-nixos-router-over-opnsense.md) had already chosen NixOS over OPNsense when the Pi was the only spare hardware; this record revisits the platform and sets the target shape of the network beyond the single DMZ of [0004](0004-dmz-vlan-segmentation.md).

## Decision

The router stays on NixOS. Reproducibility from this repository is a core priority, and NixOS keeps the router declarative in the same flake as the rest of the homelab, under the same secrets and review-and-apply workflow. The Raspberry Pi remains the router, and any later hardware swap would carry the existing configuration across unchanged.

The target shape of the network is a zoned model: distinct zones for WAN, LAN, servers and cluster, a true DMZ for any genuinely public-facing host, and management. The router is the single inter-zone gateway, enforcing default-deny with explicit allows and a documented IP scheme. The main change this implies is splitting VLAN 20 into a trusted servers zone and a separate DMZ. The re-segmentation is a direction here; the platform decision is what shipped.

## Options considered

- NixOS on the existing router, chosen. It keeps the whole edge in one flake under one workflow, and the firewall, DHCP, and DNS stay plain reviewable modules. The security features OPNsense bundles, Suricata among them, can be declared on NixOS when they are wanted rather than adopted as a package.
- OPNsense on a dedicated appliance. A mature firewall with a polished interface and turnkey IDS and IPS, but its configuration lives in its own XML and web UI, outside this repository, which breaks the single-source-of-truth model the rest of the homelab depends on.
- VyOS. Genuinely declarative and router-grade, with commit-based config, a zone-based firewall, and dynamic routing on a solid track record. The cost is that it is a second configuration system standing alongside NixOS, so consistency was the deciding factor against it.

## Consequences

The router stays reproducible from the repository, and nothing about the network leaves the declarative model. The single-VLAN design was recorded as a known simplification, with re-segmentation as a dedicated upcoming phase carried out on the Raspberry Pi and not gated on new hardware. It pairs with the defense-in-depth work in [0017](0017-defense-in-depth-baseline.md), where network policies harden the cluster from the inside while zoning hardens it from the network. Adopting OPNsense later remains possible, but it would mean accepting router configuration that lives outside the repository. The concrete IP-range and zone plan deferred here is settled in [0016](0016-concrete-zoned-ip-scheme.md).

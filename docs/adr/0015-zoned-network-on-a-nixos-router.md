---
status: accepted
date: 2026-06-13
---

# 0015. Keep the router on NixOS and move toward a zoned network model

## Context

The homelab network grew organically. Today the router is a Raspberry Pi running NixOS, declared in this repository and wired router-on-a-stick behind a Telekom Speedport that holds the WAN. A TP-Link TL-SG108E carries the tags at layer 2. VLAN 20 is a DMZ, `192.168.20.0/24`, that holds the entire K3s cluster; the home LAN sits on `192.168.2.0/24` behind the Speedport; a WireGuard hub serves `10.100.0.0/24`; and AdGuard on the router answers split-horizon DNS for `syslabs.dev`.

That single VLAN now conflates two trust levels. It is both the trusted production network for admin surfaces (rancher, grafana, longhorn, pgadmin, internal APIs) and the origin for the public-facing services that the Cloudflare tunnel fronts (chat, llm, n8n). There is no network-layer boundary between the two; isolation between a public workload and a trusted one rests entirely on Cloudflare Access and per-app authentication, as recorded in [0014](0014-declarative-minimal-cloudflare-exposure.md).

A move to a dedicated OPNsense firewall appliance was floated, which is worth a deliberate decision rather than a drift. [0003](0003-nixos-router-over-opnsense.md) already chose NixOS over OPNsense when the Pi was the only spare hardware; this record revisits the platform now that an x86 upgrade is on the table, and sets the target shape of the network beyond the single DMZ of [0004](0004-dmz-vlan-segmentation.md).

## Decision

The router stays on NixOS. Reproducibility from this repository is a core priority, and NixOS keeps the router declarative in the same flake as the rest of the homelab, under the same secrets and review-and-apply workflow. The hardware upgrade path, when more interfaces or throughput are wanted, is a small fanless x86 mini-PC of the Intel N100 or N150 class with several Intel 2.5GbE NICs. Until then the Raspberry Pi remains the router, and a swap carries the existing configuration across unchanged: the WireGuard hub, the split-horizon DNS, and the firewall all move with it.

The target shape of the network is a zoned model: distinct zones for WAN, LAN (personal devices), servers and cluster, a true DMZ for any genuinely public-facing host, and management. The router is the single inter-zone gateway, enforcing default-deny with explicit allows and a documented IP scheme. The main change this implies is splitting today's VLAN 20 into a trusted servers zone and a separate DMZ. The re-segmentation is a direction, not yet implemented; the platform decision is what ships now.

## Options considered

- NixOS on the existing router, chosen. It keeps the whole edge in one flake under one workflow, and the firewall, DHCP, and DNS stay plain reviewable modules. The security features OPNsense bundles, Suricata among them, can be declared on NixOS when they are wanted rather than adopted as a package.
- OPNsense on a dedicated appliance. A mature firewall with a polished interface and turnkey IDS and IPS, but its configuration lives in its own XML and web UI, outside this repository, which breaks the single-source-of-truth model the rest of the homelab depends on.
- VyOS. Genuinely declarative and router-grade, with commit-based config, a zone-based firewall, and dynamic routing on a solid track record. The cost is that it is a second configuration system standing alongside NixOS, so consistency was the deciding factor against it.

## Consequences

The router stays reproducible from the repository, and nothing about the network leaves the declarative model. The current single-VLAN design is recorded as a known simplification: re-segmenting VLAN 20 into a trusted servers zone and a separate DMZ is future work, gated on the hardware upgrade and not urgent. It pairs with the defense-in-depth work already on the roadmap, where network policies harden the cluster from the inside while zoning hardens it from the network. Adopting OPNsense later remains possible, but it would mean accepting router configuration that lives outside the repository. A follow-up record is owed once the concrete IP-range and zone plan is settled.

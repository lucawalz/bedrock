---
status: accepted
date: 2026-06-13
---

# 0012. Harden the router declaratively before it faces the internet

## Context

The router is the inter-zone gateway and, with the tunnel kept under [0014](0014-declarative-minimal-cloudflare-exposure.md), the box that mediates every crossing between the cluster, the DMZ, the home LAN, and the internet. Its firewall once opened management ports on every interface, which is acceptable behind the home line but not for a box that gates trust boundaries. The hardening has to be declarative like the rest of the router, not a one-off set of manual rules.

## Decision

The router is hardened declaratively. The firewall defaults to deny between zones, with explicit allows for the trusted cluster and WireGuard zones and a default-deny posture for everything else. No management services, not SSH, DNS, DHCP, or the AdGuard interface, listen where they are not wanted, and only the required ports are forwarded. The rules live in the same flake as the rest of the router, in `modules/router/firewall.nix`.

## Options considered

- Declarative hardening on the NixOS router, chosen. A small, observable surface, defined in the same flake as everything else.
- Lean on an upstream device for protection. Not viable, since the home line is the perimeter and there is nothing upstream left to lean on.

## Consequences

The inter-zone surface is small and observable, at the cost of more configuration to write and maintain. The zoned nftables firewall with default-deny between zones is in place: the cluster on VLAN 20 and the WireGuard overlay are trusted, while the VLAN 30 DMZ may reach only the internet and is dropped toward both the cluster and the home LAN. No intrusion detection system or behavioral blocker is deployed: Suricata and CrowdSec are not in place, and any such layer remains future work rather than a current claim. The honest limit is that volumetric denial-of-service cannot be solved at home, because it is an upstream problem that no edge configuration can absorb. The hardening builds on the NixOS router from [0003](0003-nixos-router-over-opnsense.md), and the zone definitions it enforces are recorded in [0016](0016-concrete-zoned-ip-scheme.md).

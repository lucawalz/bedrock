---
status: accepted
date: 2026-06-13
---

# 0012. Harden the router declaratively before it faces the internet

## Context

Once the router carries a public address (see [0011](0011-self-hosted-edge.md)) it becomes the internet-facing perimeter. Its firewall currently opens management ports on every interface, which is acceptable behind the home line but not once the box faces the open internet. The hardening has to be declarative like the rest of the router, not a one-off set of manual rules.

## Decision

The router is hardened declaratively before it goes public. The WAN input defaults to deny. No management services, not SSH, DNS, DHCP, or the AdGuard interface, listen on the WAN, and only the required ports are forwarded. An intrusion detection system (Suricata) and a behavioral blocker (CrowdSec) run on the edge, with their logs shipped to the existing Grafana.

## Options considered

- Declarative hardening on the NixOS router, chosen. A small, observable WAN surface, defined in the same flake as everything else.
- Lean on an upstream device for protection. Not viable once the Cloudflare tunnel is gone and the home line is the perimeter, so there is nothing upstream left to lean on.

## Consequences

The WAN surface is small and observable, at the cost of more configuration to write and maintain. The honest limit is that volumetric denial-of-service cannot be solved at home, because it is an upstream problem that no edge configuration can absorb. This is accepted but not yet implemented. The hardening builds on the NixOS router from [0003](0003-nixos-router-over-opnsense.md).

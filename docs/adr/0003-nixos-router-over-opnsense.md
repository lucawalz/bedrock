---
status: accepted
date: 2026-06-12
---

# 0003. Run the edge router on NixOS instead of OPNsense

## Context

The homelab needed a real layer-3 router and firewall to put the cluster on its own DMZ and, later, to face the public internet. The existing edge devices cannot do this: the Telekom Speedport has no VLANs or inter-network rules, and the TP-Link TL-SG108E only tags VLANs at layer 2. The spare hardware for the job is a Raspberry Pi 4B, which is aarch64. Every other host in this repository is already declared in NixOS and reconciled from Git, so the router had to fit that model rather than become a hand-configured exception.

## Decision

The router runs NixOS, defined as another host in this repository under `hosts/router/` and `modules/router/`. OPNsense was the main alternative and was rejected: it ships only for amd64 on a FreeBSD base and does not run on the aarch64 Pi, so choosing it would have meant buying x86 hardware for a job the Pi already does. NixOS keeps the router under the same flake, the same secrets handling, and the same review-and-apply workflow as the cluster nodes.

## Options considered

- NixOS on the Raspberry Pi, chosen. It runs on aarch64, needs no new hardware, and the firewall, DHCP, and DNS are plain modules (nftables, kea, AdGuard) that are versioned and reviewed alongside everything else.
- OPNsense. A mature firewall with a polished interface, but amd64-only and BSD-based, so it cannot run on the Pi and would split the estate across two configuration models and a second machine.
- A consumer router with custom firmware. Cheap and simple, but its configuration lives on the device rather than in Git, which breaks the reproducibility the rest of the project depends on.

## Consequences

Router state is reproducible and reviewable: changing the firewall is an edit to the flake and an apply, not a click through a web interface. Logs ship to the same Grafana as the cluster, so the edge is observable without a separate console. The cost is that features OPNsense bundles behind a GUI, including the intrusion detection and the DHCP and DNS services, are assembled by hand from NixOS options, which is more work up front and demands more networking knowledge. Hardening the box for public exposure is tracked separately in [0012](0012-bulletproof-router-hardening.md).

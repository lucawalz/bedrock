---
status: superseded by 0023
date: 2026-06-13
---

# 0010. Self-host a WireGuard overlay to replace ZeroTier

## Context

The cluster nodes and the remote cloud burst nodes needed a private overlay so the control plane sat on a stable address and a cloud node could join across the open internet. That overlay was ZeroTier, which routes peers through ZeroTier's public root servers, putting a third party in the data path. The homelab already declared its router and secrets in Git, and an overlay that depends on someone else's infrastructure did not fit that model.

## Decision

A self-hosted WireGuard hub runs on the NixOS router from [0003](0003-nixos-router-over-opnsense.md), replacing ZeroTier. WireGuard is in the kernel, declared in the router's NixOS config, and answers only authenticated peers, so it is silent to scanners. The router becomes the hub, and both cluster nodes and burst nodes peer with it directly.

## Options considered

- Self-hosted WireGuard, chosen. In-kernel, declarative, and free of any third party in the path.
- Keep ZeroTier. It works and joins are easy, but it routes through ZeroTier's roots and is less declarative.
- NetBird. Self-hostable, but a heavier control plane to run, with its own reliability and CVE history.
- Tailscale. Smooth to operate, but its control plane is a managed third party, the thing this move was meant to remove.

## Consequences

Peer management became explicit and manual but stayed declarative and auditable, with keys handled by the secrets model in [0007](0007-agenix-sops-secrets.md). The home line became the WireGuard endpoint, so that public address had to stay out of committed config. The hub ran on the Pi as `wg0` on `10.100.0.1/24` and served the admin workstation and the Hetzner burst nodes as peers, and ZeroTier was removed everywhere. The trade the last option describes was later reversed: [0023](0023-tailscale-overlay.md) accepted the managed control plane and replaced the hub with Tailscale.

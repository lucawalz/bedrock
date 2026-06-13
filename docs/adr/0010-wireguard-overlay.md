---
status: accepted
date: 2026-06-13
---

# 0010. Self-host a WireGuard overlay to replace ZeroTier

## Context

The cluster nodes and the remote cloud burst nodes need a private overlay so the control plane sits on a stable address and a cloud node can join across the open internet. Today that overlay is ZeroTier, which routes peers through ZeroTier's public root servers, putting a third party in the data path. The homelab already declares its router and secrets in Git, and an overlay that depends on someone else's infrastructure does not fit that model.

## Decision

A self-hosted WireGuard hub runs on the NixOS router, replacing ZeroTier. WireGuard is in the kernel, declared in the router's NixOS config, and answers only authenticated peers, so it is silent to scanners. The router becomes the hub, and both cluster nodes and burst nodes peer with it directly.

## Options considered

- Self-hosted WireGuard, chosen. In-kernel, declarative, and free of any third party in the path.
- Keep ZeroTier. It works and joins are easy, but it routes through ZeroTier's roots and is less declarative.
- NetBird. Self-hostable, but a heavier control plane to run, with its own reliability and CVE history.
- Tailscale. Smooth to operate, but its control plane is a managed third party, the thing this move is meant to remove.

## Consequences

Peer management becomes explicit and manual, but stays declarative and auditable, with keys handled by the secrets model in [0007](0007-agenix-sops-secrets.md). The home line becomes the WireGuard endpoint, so that public address must stay out of committed config. This is implemented: the hub runs on the Pi as `wg0` on `10.100.0.1/24` and serves the admin workstation and the Hetzner burst nodes as peers. ZeroTier has been removed everywhere, and the WireGuard hub has fully replaced it. The router that hosts the hub is the NixOS box from [0003](0003-nixos-router-over-opnsense.md).

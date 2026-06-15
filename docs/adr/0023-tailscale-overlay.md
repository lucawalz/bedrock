---
status: accepted
date: 2026-06-15
---

# 0023. Replace the self-hosted WireGuard overlay with Tailscale

## Context

[0010](0010-wireguard-overlay.md) put a self-hosted WireGuard hub on the NixOS router so the admin workstation and the cloud burst nodes could reach the cluster over a private overlay. In practice the hub carried real cost. Every peer was a hand-managed entry in the router config, each burst node needed key material injected at provisioning time and a oneshot service to raise `wg0` before k3s could start, and the home line had to act as a fixed WireGuard endpoint whose public address could not live in committed config. The overlay worked, but it was the most fragile and least automatic part of the setup, and it stood in the way of moving burst capacity onto Cluster API.

## Decision

Tailscale replaces the self-hosted WireGuard hub. The Pi router runs as a Tailscale subnet router and advertises the trusted `10.20.0.0/24` range, so the admin workstation and any tailnet member reach the cluster without a manual peer list. Burst nodes join the tailnet at boot from an auth key and ride the same overlay, which removes the bespoke key injection and the `wg0`-up dance. The router keeps AdGuard as the LAN resolver, so Tailscale is told not to manage DNS.

## Options considered

- Tailscale, chosen. A managed control plane removes peer bookkeeping, gives burst nodes a one-line join, and fits the Cluster API direction. The cost is a third party in the control plane, though not in the data path between peers.
- Keep the self-hosted WireGuard hub. It has no third party at all, but every peer and burst node is manual, and it was the main obstacle to automated burst capacity.
- A different self-hosted mesh such as NetBird or Headscale. Self-hostable, but each is another control plane to run and keep patched, which is the operational weight this change is meant to shed.

## Consequences

Peer and burst onboarding becomes automatic, and the home line no longer has to publish a stable WireGuard endpoint. The trade against [0010](0010-wireguard-overlay.md) is deliberate: a managed control plane is accepted in exchange for far less manual overlay maintenance and a clean path to Cluster API burst nodes. Keys are still handled by the secrets model in [0007](0007-agenix-sops-secrets.md), now as the Tailscale auth key rather than a WireGuard private key. The router that hosts the subnet router is the NixOS box from [0003](0003-nixos-router-over-opnsense.md). The self-hosted WireGuard overlay and every reference to it have been removed from the repository. The orphaned `wg0` interface on the running router is not recreated by the declarative config and clears on the next router reboot.

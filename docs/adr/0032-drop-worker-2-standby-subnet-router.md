---
status: accepted
date: 2026-06-17
---

# 0032. Drop the worker-2 standby subnet router

## Context

The burst overlay needs working pod VXLAN between the home nodes and the Hetzner burst nodes over the tailnet. Following [0023](0023-tailscale-overlay.md), worker-2 ran as a standby Tailscale subnet router advertising `10.20.0.0/24`, which made it the only home node directly on the tailnet.

That placement created an asymmetric path. worker-2 reached a burst node directly over `tailscale0`, while the burst node reached worker-2 through the Pi subnet router. The two directions never agreed on a route, so the burst-to-worker-2 pod VXLAN passed zero traffic, down to the smallest packets, while burst-to-master and burst-to-worker-1 worked normally.

CoreDNS runs on worker-2, so burst-node DNS resolution died with that one broken leg. The failure then cascaded into Longhorn and csi-plugin timeouts on the burst nodes, which were initially mis-attributed to MTU before the asymmetric tailnet path was identified as the real cause.

## Decision

Remove worker-2's standby subnet router. The change strips the per-host subnet-router wiring from `lib/default.nix`, drops `tailscale-authkey-worker-2.age` from `secrets/secrets.nix` and `secrets/README.md`, and deletes the encrypted `secrets/tailscale-authkey-worker-2.age` itself.

The Pi router becomes the sole subnet router advertising `10.20.0.0/24` to the tailnet. With no home node sitting on the tailnet directly, every home node reaches a burst node through the same Pi-routed path the burst node uses in return, restoring a symmetric route for the overlay.

## Consequences

The Pi is now the single point that advertises `10.20.0.0/24`, and its route must remain approved in the tailnet for the burst overlay to function at all. This reintroduces the single-point-of-dependency that [0023](0023-tailscale-overlay.md) added the standby to avoid, traded knowingly: the standby's redundancy was never realised in practice because its asymmetric path black-holed exactly the traffic the overlay depends on, so a working symmetric route through one advertiser is preferable to a broken pair. If the Pi is offline, tailnet access to the lab is lost until it returns or another approved advertiser is brought up.

No home node is a tailnet member anymore, so the secrets model from [0007](0007-agenix-sops-secrets.md) carries only the primary router auth key. This supersedes the part of [0023](0023-tailscale-overlay.md) that put a standby subnet router on worker-2; the rest of that decision, the move from self-hosted WireGuard to Tailscale with the Pi as primary subnet router, still stands.

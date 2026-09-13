---
status: superseded by 0014
date: 2026-06-13
---

# 0011. Own the edge with a port-forward instead of a Cloudflare tunnel

## Context

Inbound web traffic went through a Cloudflare Tunnel. The tunnel terminates TLS at Cloudflare's edge and keeps the home address hidden, which is useful, but it adds a third party to every request and could not carry every workload, including the streaming one. The home line has a genuine public IPv4, so owning the edge was possible without renting anything.

## Decision

The Cloudflare tunnel is dropped and the edge is owned outright. The router forwards 80 and 443 to the in-cluster Traefik, TLS is terminated in-cluster with the cert-manager wildcard, and Cloudflare is kept for DNS only.

## Options considered

- Own the edge via port-forward, chosen. Full control, at no rental cost, on an address the home line already has.
- Keep the Cloudflare tunnel. The status quo, whose only advantage over this decision is the hidden home address.
- Rent a VPS as a public front. It would hide the address, but it reintroduces a rented box, and the goal was to be fully self-hosted.

## Consequences

Owning the edge would have published the home public address in DNS and made the home line the perimeter that absorbs scanning and denial-of-service. Hiding the address was not possible without an external front, which was deliberately rejected. The exposure would have been narrowed by forwarding only the needed ports, by the wildcard certificate from [0006](0006-cert-manager-dns01.md) that keeps subdomain names out of public Certificate Transparency logs, by routing through the Traefik ingress in [0008](0008-traefik-ingress.md), and by the router hardening in [0012](0012-bulletproof-router-hardening.md). None of it was implemented: [0014](0014-declarative-minimal-cloudflare-exposure.md) judged that exposure larger than the workloads justified and kept the tunnel, managing it from the repository instead.

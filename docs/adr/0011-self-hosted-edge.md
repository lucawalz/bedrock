---
status: accepted
date: 2026-06-13
---

# 0011. Own the edge with a port-forward instead of a Cloudflare tunnel

## Context

Inbound web traffic goes through a Cloudflare Tunnel today. The tunnel terminates TLS at Cloudflare's edge and keeps the home address hidden, which is useful, but it adds a third party to every request and cannot carry every workload, including the streaming one. The home line has a genuine public IPv4, so owning the edge is possible without renting anything.

## Decision

The Cloudflare tunnel is dropped and the edge is owned outright. The router forwards 80 and 443 to the in-cluster Traefik, TLS is terminated in-cluster with the cert-manager wildcard, and Cloudflare is kept for DNS only.

## Options considered

- Own the edge via port-forward, chosen. Full control, no third party in the request path, and it can carry every workload.
- Keep the Cloudflare tunnel. It hides the home address, but it is a third party on every request and cannot carry the streaming workload.
- Rent a VPS as a public front. It would hide the address, but it reintroduces a rented box, and the goal is to be fully self-hosted.

## Consequences

The edge is fully controlled, but the home public address is now published in DNS, and the home line becomes the perimeter that absorbs scanning and denial-of-service. Hiding the address is not possible without an external front, which was deliberately rejected. The exposure is narrowed by forwarding only the needed ports, by the wildcard certificate from [0006](0006-cert-manager-dns01.md) that keeps subdomain names out of public Certificate Transparency logs, by routing through the Traefik ingress in [0008](0008-traefik-ingress.md), and by the router hardening in [0012](0012-bulletproof-router-hardening.md). This is accepted but not yet implemented.

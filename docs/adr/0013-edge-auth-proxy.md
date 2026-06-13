---
status: rejected
date: 2026-06-13
---

# 0013. Choose an edge authentication proxy

## Context

With services exposed directly (see [0011](0011-self-hosted-edge.md)), each one should sit behind a single sign-on gate rather than its own login. That gate is the internet-facing auth boundary, so both its maturity and how its configuration is managed matter. The decision is open. Three candidates remain, and the choice turns on one unresolved question: whether the homelab needs a full identity provider, an OIDC provider that other apps authenticate against, or only a forward-auth gate in front of Traefik.

## Decision

Rejected. No in-cluster auth proxy is adopted. Under [0014](0014-declarative-minimal-cloudflare-exposure.md) the tunnel stays in place and Cloudflare Access remains the single sign-on gate for the exposed hosts, so a separate edge proxy duplicates a boundary that already exists.

## Options considered

No decision has been made. Security is roughly even across the three, so the real differentiators are operational weight, how much configuration lives in Git, and whether a full identity provider is wanted.

- Pangolin. One cohesive tool with the best add-and-forget experience, but its headline feature is an outbound tunnel that hides the home address, which this design does not use. Self-hosted behind the port-forward, it duplicates both the in-cluster Traefik and the WireGuard overlay, is the youngest of the three as a public gate, and has moved to an open-core license.
- Traefik with Authentik. Adds a forward-auth layer to the Traefik already in use and brings a full identity provider and dashboard, at the cost of more weight, a database and a worker, and a forward-auth CVE history that needs a hardening checklist.
- Traefik with Authelia. The lightest forward-auth gate, almost entirely file-configured with the smallest surface, but a gate only and not an identity provider.

## Consequences

The decision is deferred until the identity-provider question is answered. Whichever is chosen is an additive layer on the existing Traefik from [0008](0008-traefik-ingress.md), except Pangolin, which would replace parts of the edge from [0011](0011-self-hosted-edge.md).

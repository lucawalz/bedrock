---
status: rejected
date: 2026-06-13
---

# 0013. Choose an edge authentication proxy

## Context

With services exposed directly under [0011](0011-self-hosted-edge.md), each one would have sat behind a single sign-on gate rather than its own login. That gate would have been the internet-facing auth boundary, so both its maturity and how its configuration was managed mattered. Security was roughly even across the three candidates, so the real differentiators were operational weight, how much configuration lived in Git, and whether a full identity provider was wanted at all.

## Decision

Rejected. No in-cluster auth proxy is adopted at the edge. Under [0014](0014-declarative-minimal-cloudflare-exposure.md) the tunnel stays in place and Cloudflare Access remains the single sign-on gate for the exposed hosts, so a separate edge proxy duplicates a boundary that already exists.

## Options considered

- Pangolin. One cohesive tool with the best add-and-forget experience, but its headline feature was an outbound tunnel that hid the home address, which that design did not use. Self-hosted behind the port-forward it duplicated both the in-cluster Traefik and the WireGuard overlay, was the youngest of the three as a public gate, and had moved to an open-core license.
- Traefik with Authentik. It would have added a forward-auth layer to the Traefik already in use and brought a full identity provider and dashboard, at the cost of more weight, a database and a worker, and a forward-auth CVE history that needed a hardening checklist.
- Traefik with Authelia. The lightest forward-auth gate, almost entirely file-configured with the smallest surface, but a gate only and not an identity provider.

## Consequences

Public hosts kept Cloudflare Access as their gate. The identity-provider question this record left open was answered separately for the internal dashboards by [0038](0038-authentik-sso-for-internal-dashboards.md), which chose Authentik with Traefik forward auth, so the second option here was adopted one layer in rather than at the edge.

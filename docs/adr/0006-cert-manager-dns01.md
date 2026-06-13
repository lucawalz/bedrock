---
status: accepted
date: 2025-11-02
---

# 0006. Issue certificates with cert-manager over Cloudflare DNS-01

## Context

Services need real TLS certificates, renewed automatically, with nobody minding expiry dates. The cluster has no open inbound ports: external traffic arrives through a Cloudflare Tunnel, not a port forward. That rules out any issuance method that needs Let's Encrypt to reach the cluster directly. A single wildcard would also be convenient, since it covers every subdomain at once.

## Decision

cert-manager issues Let's Encrypt certificates through the Cloudflare DNS-01 solver, configured as a ClusterIssuer in `infrastructure/networking/cert-manager/cluster-issuers/`. DNS-01 proves control by writing a TXT record through the Cloudflare API, so it needs no inbound connection and supports wildcards, which fits a cluster with no open ports.

## Options considered

- DNS-01 via Cloudflare, chosen. No inbound port required, supports wildcard certificates, and renewals are fully automatic through the Cloudflare API.
- HTTP-01. Simpler to reason about, but it needs Let's Encrypt to reach the cluster on port 80 and cannot issue wildcards, both of which conflict with the no-inbound-ports design.
- Manual certificates. No dependency on any API token, but renewal becomes a recurring chore and a likely outage, which defeats the point.

## Consequences

Certificates renew on their own and a single wildcard covers every service, which also keeps individual subdomain names out of Certificate Transparency logs. The cost is a dependency on a SOPS-encrypted Cloudflare API token scoped to DNS edits: that token is now part of the trust chain and has to be guarded and rotated like any other secret.

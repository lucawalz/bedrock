---
status: accepted
date: 2026-06-14
---

# 0021. Serve the public blog and portfolio at the lucawalz.dev apex

## Context

The blog launched at `blog.syslabs.dev`, a subdomain of the cluster's own zone. That was convenient while it was the only public-facing prose on the cluster, but it tied a personal brand to an infrastructure domain and split future search authority across hostnames. The blog has grown into a combined blog and portfolio, which is the public face of the work rather than another cluster service, so it warranted a domain of its own and a deliberate choice about where the content sits within it.

Two questions had to be settled together: which domain the site lives on, and whether the blog stays a subdomain or becomes a path on a single site.

## Decision

The blog and portfolio are served at the apex `lucawalz.dev`. This is a full migration off `blog.syslabs.dev`: the old host is removed from the Cloudflare tunnel and no longer routed, not redirected. Public TLS still terminates at Cloudflare's edge and the tunnel hop to Traefik stays on `noTLSVerify`, so the move is a hostname change in the tunnel ingress and the Traefik IngressRoute with no internal certificate change.

It stays one site. The blog is a path under the apex at `/posts` rather than a `blog.` subdomain, so the apex serves the portfolio and the writing as a single property.

## Options considered

- `lucawalz.dev` at the apex, one site with the blog as a path, chosen. A `.dev` apex reads as a developer's home on the web, sits consistently alongside the cluster's `syslabs.dev`, and is on the HSTS preload list, so browsers force HTTPS for the whole zone before the first request is even sent. Keeping the blog as a subdirectory consolidates the domain's authority on one hostname.
- `lucawalz.com` at the apex. The `.com` carries no ranking advantage; Google treats the top-level domain as SEO-neutral, so the choice is one of brand rather than reach. A `.dev` fits a developer brand more closely and keeps the public domain in the same family as `syslabs.dev`, and `.com` brings no HTTPS-by-default guarantee of its own.
- Keep the blog on a `blog.` subdomain. A subdomain is read as a separate site for ranking purposes, so it fragments authority between the apex and the subdomain instead of building it on one host. A subdirectory keeps everything on a single hostname and avoids that split.

## Consequences

The public site now lives on a domain that belongs to the person rather than the cluster, and the writing and portfolio share one hostname, so search authority accrues to a single property. Because the move is a clean cutover rather than a redirect, any old links to `blog.syslabs.dev` stop resolving once the host is removed; this is accepted given the low traffic and short life of the original host. Public TLS continues to terminate at Cloudflare's edge, so no cert-manager certificate changes, and the `.dev` zone's HSTS preload means the apex is HTTPS-only by default without further configuration. ADR 0019 still describes how the site is built and hardened; this record only fixes where it is published.

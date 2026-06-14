---
status: accepted
date: 2026-06-14
---

# 0019. Self-host a static blog

## Context

A public blog was wanted at the apex `lucawalz.dev`, served from the cluster through the existing Cloudflare tunnel. Because it would be a public-facing service, its attack surface mattered more than its feature set. It also raised a separation question: blog content and cluster infrastructure change for different reasons and on different cadences, so mixing prose and manifests in one repository would couple two concerns that are better kept apart. The blog first ran at `blog.syslabs.dev`; that host has since been retired and removed from the tunnel, with the domain choice recorded in ADR 0021.

## Decision

The blog is a static [Hugo](https://gohugo.io/) site served at the apex `lucawalz.dev`, public through the Cloudflare tunnel. Content lives in a separate public repository, [lucawalz/blog](https://github.com/lucawalz/blog), so authoring is markdown in Git and stays independent of cluster infrastructure. GitHub Actions builds a container image on each change, compiling the site with Hugo and serving it from nginx, and pushes it to a public GHCR package at `ghcr.io/lucawalz/blog`. bedrock pins that image by tag and serves it behind Traefik with a hardened Deployment: a read-only root filesystem, a non-root securityContext, and a default-deny NetworkPolicy in its namespace.

The deploy model is deliberately manual. The image is pinned by tag, and publishing a post is a tag bump committed to this repository, which Flux then reconciles. Flux Image Update Automation is deferred: it would let the cluster track new tags hands-off, but it needs extra controllers and Git write-back from the cluster, which is more machinery than a personal blog warrants for now.

## Options considered

- A static Hugo site in a separate content repository, chosen. No database and no server-side rendering means a small attack surface for a public service, a footprint around 50 MB, markdown-in-git authoring, and output that Cloudflare can cache in full. The separate repository keeps content and cluster concerns apart.
- A dynamic CMS such as Ghost or WriteFreely. Richer authoring and built-in publishing, but each carries a database and a running application as public attack surface, which is a poor trade for a low-traffic personal blog.
- Content in this repository alongside the manifests. One less repository to manage, but it couples prose changes to infrastructure changes and clutters the cluster history with post edits.

## Consequences

The public surface is a single static site behind nginx with a read-only root filesystem, no database, and a default-deny NetworkPolicy, so a compromise has little to reach and nothing to write. Content authors work in markdown in a repository of their own, and the build pipeline produces a pinned image that this repository references explicitly, so a deploy is always a reviewable commit. The cost is that publishing takes a manual tag bump rather than happening on its own; closing that gap is the optional Flux Image Update Automation upgrade, left deferred until the extra controllers and Git write-back are worth carrying.

Public reachability also depends on a DNS record for `lucawalz.dev` that points at the tunnel, created in Cloudflare rather than committed here, in keeping with the dashboard-managed DNS decision in ADR 0014. The cloudflared ingress entry routes the hostname to Traefik once it arrives, but it does not publish the hostname; without the DNS record the site stays unreachable from outside.

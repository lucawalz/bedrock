---
status: accepted
date: 2026-07-06
---

# 0019. Self-host the blog and portfolio

## Context

A public blog and portfolio was wanted at the apex `lucawalz.dev`, served from the cluster through the existing Cloudflare tunnel. Because it is public-facing, its attack surface matters more than its feature set, and blog content and cluster infrastructure change for different reasons and on different cadences, so keeping prose and manifests in one repository would couple two concerns better kept apart. This record consolidates the original build decision with the domain choice and the deploy automation that followed it. The site first ran at `blog.syslabs.dev`, since retired and removed from the tunnel.

## Decision

### Build and harden

The blog is a static [Hugo](https://gohugo.io/) site. Content lives in a separate public repository, [lucawalz/blog](https://github.com/lucawalz/blog), so authoring is markdown in Git and stays independent of cluster infrastructure. GitHub Actions builds a container image on each change, compiling the site with Hugo and serving it from nginx, and pushes it to a public GHCR package at `ghcr.io/lucawalz/blog`. bedrock serves that image behind Traefik with a hardened Deployment: a read-only root filesystem, a non-root securityContext, and a default-deny NetworkPolicy in its namespace.

### Domain

The site is served at the apex `lucawalz.dev`, a full migration off `blog.syslabs.dev` rather than a redirect, so the old host is removed from the Cloudflare tunnel and no longer routed. It stays one property, with the blog as a path at `/posts` rather than a `blog.` subdomain, so the apex serves the portfolio and the writing as a single site and search authority accrues to one hostname. Public TLS terminates at Cloudflare's edge and the tunnel hop to Traefik stays on `noTLSVerify`, so the domain choice is a hostname change in the tunnel ingress and the Traefik IngressRoute with no internal certificate change. The `.dev` zone is on the HSTS preload list, so the apex is HTTPS-only by default.

### Deploy automation

The blog deploys through Flux Image Update Automation. Its CI tags each image with a sortable `main-<timestamp>-<shortsha>` tag alongside `latest`. An ImageRepository scans the GHCR package, an ImagePolicy selects the newest image by timestamp, and an ImageUpdateAutomation writes the resulting immutable tag into the blog Deployment and commits it to `main`. The Deployment image carries the `$imagepolicy` setter marker so the controller knows which field to update, and the automation's write path is scoped to `kubernetes/clusters/home/apps/blog`, so it can only touch blog manifests. This replaces an earlier manual tag-bump model that had rotted into a floating `latest` tag, where a rebuild left the pod spec unchanged and nothing redeployed.

## Options considered

- A static Hugo site in a separate content repository, chosen. No database and no server-side rendering means a small attack surface, markdown-in-git authoring, and output Cloudflare can cache in full, while the separate repository keeps content and cluster concerns apart. A dynamic CMS such as Ghost or WriteFreely carries a database and a running application as public attack surface, a poor trade for a low-traffic personal site, and content in this repository alongside the manifests would couple prose edits to infrastructure history.
- The `lucawalz.dev` apex as a single site, chosen. A `.dev` apex reads as a developer's home, sits alongside the cluster's `syslabs.dev`, and forces HTTPS through HSTS preload. A `.com` carries no ranking advantage and no HTTPS-by-default guarantee, and a `blog.` subdomain fragments search authority across hostnames instead of consolidating it on one.
- Flux Image Update Automation for deploys, chosen. It keeps Git the source of truth and ties every deploy to an immutable, reviewable tag with nothing beyond the controllers the Flux bootstrap already installs. A CI `kubectl rollout restart` cannot reach an API server that is internal-only and moves deploy authority out of Git, a registry watcher such as Keel adds a controller outside the Flux model, and a hand-bumped pinned tag is the toil this removes.

## Consequences

The public surface is a single static site behind nginx with a read-only root filesystem, no database, and a default-deny NetworkPolicy, so a compromise has little to reach and nothing to write. Content authors work in markdown in a repository of their own, and publishing a post is hands-off: a push builds an image, Flux picks up the new immutable tag, rewrites the Deployment, and the site updates with no manual step, every deploy pinned in Git history rather than to a floating `latest`. Because the image-automation controller commits to `main`, this repository can move ahead of a local checkout, so a pull is needed before pushing by hand, the same caveat that applies with Renovate.

Public reachability depends on a DNS record for `lucawalz.dev` that points at the tunnel, created in Cloudflare rather than committed here, in keeping with the dashboard-managed DNS decision in [0014](0014-declarative-minimal-cloudflare-exposure.md). The cloudflared ingress entry routes the hostname to Traefik once it arrives but does not publish it; without the DNS record the site stays unreachable from outside. Because the cutover off `blog.syslabs.dev` is a clean removal rather than a redirect, any old links to that host stop resolving, accepted given its low traffic and short life.

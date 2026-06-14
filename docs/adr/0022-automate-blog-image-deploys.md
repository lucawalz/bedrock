---
status: accepted
date: 2026-06-14
---

# 0022. Automate blog image deploys with Flux Image Update Automation

## Context

ADR 0019 stood up the blog as a static site built in its own repository and deferred Flux Image Update Automation, on the grounds that it needed extra controllers and Git write-back that were not yet worth carrying. In practice the manual model was never wired. The Deployment referenced the floating `latest` tag rather than a pinned one, so a push rebuilt the image but nothing redeployed: a mutable tag leaves the pod spec unchanged, so Flux reconciles to a no-op, and `imagePullPolicy: Always` only pulls when a pod is created, never for one already running. Shipping a post meant a manual `kubectl rollout restart`, a hidden step and a break in the GitOps model.

The two prerequisites ADR 0019 named are now in place. The cluster already runs the image-reflector and image-automation controllers from the Flux bootstrap, and the `flux-cd` deploy key has write access, so the cluster can commit image updates back to this repository.

## Decision

The blog deploys through Flux Image Update Automation. Its CI tags each image with a sortable `main-<timestamp>-<shortsha>` tag alongside `latest`. An ImageRepository scans the public GHCR package, an ImagePolicy selects the newest image by the numeric timestamp, and an ImageUpdateAutomation writes the resulting immutable tag into the blog Deployment and commits it to `main`. The Deployment image carries the `$imagepolicy` setter marker so the controller knows which field to update. The automation's write path is scoped to `kubernetes/clusters/home/apps/blog`, so it can only touch blog manifests.

## Options considered

- Flux Image Update Automation, chosen. It keeps Git the source of truth, ties every deploy to an immutable and reviewable tag, and needs nothing beyond the controllers the bootstrap already installed. The cost is that the cluster now commits to `main`.
- CI runs `kubectl rollout restart` against the cluster. Simple, but the API server is reachable only over WireGuard and the LAN, so a hosted runner cannot reach it without exposing the API or running a self-hosted runner, and it moves deploy authority out of Git.
- A registry watcher such as Keel. It works, but adds a controller outside the Flux model for a problem Flux already solves.
- Stay manual with a real pinned tag and bump it by hand. Honest and simple, but it is the toil this change removes, and it had already rotted into `latest`.

## Consequences

Publishing a post is now hands-off. A push to the blog repository builds an image, Flux picks up the new tag and rewrites the Deployment, and the site updates with no manual step. Deploys are pinned to immutable tags in Git history rather than a floating `latest`, which is what ADR 0019 intended. Because the image-automation controller commits to `main`, this repository can move ahead of a local checkout, so a pull is needed before pushing by hand, the same caveat that already applies with Dependabot. The manual tag-bump model described in ADR 0019 is superseded by this decision.

---
status: accepted
date: 2026-06-16
---

# 0028. Route alerts and reconciliation failures to a self-hosted ntfy

## Context

Alertmanager shipped with a single `null` receiver and Flux had no `Provider` or `Alert` objects, so
every Prometheus alert and every reconciliation failure was silently discarded. The estate keeps
internal services off the public internet, with public exposure limited to the tunnel hosts
([0014](0014-declarative-minimal-cloudflare-exposure.md)), so the sink should follow that posture.

## Decision

Self-host ntfy as an internal-only service at `ntfy.syslabs.dev`, deployed as a Flux HelmRelease from
the bjw-s `app-template` chart and exposed through a Traefik IngressRoute and the split-horizon
AdGuard rewrite with no public DNS record. It first ran from a single-maintainer community chart and
moved once the estate standardized on `app-template` for plain Deployment and Service workloads.

Alertmanager's default route posts a webhook carrying the title and message as URL-encoded Go
templates, which keeps the notification compact; `send_resolved` stays on, the `InfoInhibitor` matcher
keeps its `null` sub-route, and the `Watchdog` matcher routes to a `deadman` receiver instead.
Grafana's unified alerting posts to the same endpoint, and Flux publishes through a `generic` Provider
and an `Alert` scoped to `eventSeverity: error`. ntfy runs without authentication and without
persistence, because its NetworkPolicy admits only Traefik, monitoring, and flux-system, and it is
reachable only over the overlay or the LAN.

## Options considered

- Self-hosted ntfy, chosen. It keeps alert content on the network and needs one deployed component.
- An `ntfy-alertmanager` bridge, rejected: templating covers the need and a bridge adds a second
  component from a personal registry.
- ntfy.sh SaaS, rejected: zero ops, but alert content and topic names leave the lab.
- Self-hosted gotify, rejected: heavier, needs a volume, and has no native Alertmanager receiver.
- Token authentication, rejected: tokens live in a runtime database and cannot be seeded declaratively.

## Consequences

Alerts and reconciliation failures surface in ntfy instead of being discarded, visible over the
overlay or LAN. iOS background delivery stays out of reach, because it would relay poll requests
through ntfy.sh and expose topic names off the network. History is ephemeral, which suits a live sink
but keeps no archive, and the notification format lives in this repository as a percent-encoded
string, which is harder to read in review and is the reason it can be changed by a commit at all.

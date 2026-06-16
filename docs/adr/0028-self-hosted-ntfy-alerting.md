---
status: accepted
date: 2026-06-16
---

# 0028. Route alerts and reconciliation failures to a self-hosted ntfy

## Context

Alertmanager shipped with a single `null` (blackhole) receiver and Flux had no `Provider` or `Alert`
objects, so every Prometheus alert and every Flux reconciliation failure was silently discarded. The
notification-controller was running and the CRDs were installed, but nothing was wired to them, so an
outage or a failed HelmRelease produced no signal anywhere.

The estate is self-hosted with internal services kept off the public internet and reached over the
Tailscale overlay, with public exposure limited to the three tunnel hosts ([0014](0014-declarative-minimal-cloudflare-exposure.md)).
A notification sink should follow the same posture rather than depend on a third-party service or leak
alert content off the network.

## Decision

Self-host **ntfy** as an internal-only service at `ntfy.syslabs.dev`, deployed from the maintained
`oci://codeberg.org/wrenix/helm-charts/ntfy` chart (ntfy 2.24.0) as a Flux HelmRelease, exposed through
a Traefik IngressRoute and the split-horizon AdGuard rewrite with no public DNS record. Both alert
sources publish to it over the cluster network.

Alertmanager posts directly to ntfy using ntfy's built-in `alertmanager` template
(`/alerts?template=alertmanager`, `send_resolved: true`); the default route receiver becomes `ntfy`
while the `Watchdog`/`InfoInhibitor` matcher keeps its `null` sub-route. The built-in template renders
firing and resolved alerts without a separate bridge component. Flux publishes through a `generic`
Provider and an `Alert` scoped to `eventSeverity: error` for Kustomization and HelmRelease sources.

ntfy runs without authentication (`auth-default-access: read-write`) and without persistence (in-memory
cache, no PVC). This is acceptable because the service is internal-only: it carries no public DNS
record, its NetworkPolicy admits ingress only from Traefik, the monitoring namespace, and
flux-system, and it is reachable only over the VPN or LAN. Mobile push is desktop and web for now; iOS
background delivery is deferred because it would require relaying poll requests through ntfy.sh, which
would expose topic names off the network.

## Options considered

- Self-hosted ntfy with the built-in Alertmanager template, chosen. It keeps alert content on the
  network, reuses the existing internal-exposure pattern, and needs only one deployed component.
- A dedicated `ntfy-alertmanager` bridge for richer formatting. Rejected for now: the built-in template
  covers the homelab need and a bridge would add a second component from a personal registry.
- ntfy.sh SaaS. Rejected: zero ops but alert content and topic names leave the lab, against the posture.
- Self-hosted gotify. Rejected: heavier, requires a persistent volume, and has no native Alertmanager
  receiver so it would need a webhook shim.
- Token authentication on ntfy. Rejected for now: ntfy tokens live in a runtime database and cannot be
  seeded declaratively, so they would break the GitOps model for a service already gated by the VPN and
  NetworkPolicies. Auth can be layered on later if the threat model changes.

## Consequences

Prometheus alerts and Flux reconciliation failures now surface in ntfy instead of being discarded.
The sink is internal-only, so notifications are visible over the VPN or LAN and a phone needs the
overlay to receive them; iOS push remains a later decision tied to the ntfy.sh relay tradeoff. Message
history is ephemeral by design, which suits a live-alert sink but keeps no archive. The chart is a
community OCI artifact rather than a large-org chart, adding a supply-chain dependency that is pinned by
version. Alert formatting follows ntfy's shipped `alertmanager` template; overriding it later would mean
mounting a custom template into the container.

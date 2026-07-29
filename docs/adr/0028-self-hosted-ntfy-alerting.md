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

## Update 2026-07-25

Two implementation details recorded above no longer hold. Both were changed to remove a dependency,
so this record is amended rather than superseded.

The deployment no longer uses the `oci://codeberg.org/wrenix/helm-charts/ntfy` chart. Since 2026-07-11
ntfy is deployed from the bjw-s `app-template` chart at major version 5, running the upstream
`docker.io/binwiederhier/ntfy` image, currently `v2.26.3`, with `serve` as its argument. The estate had
by then standardized on `app-template` for workloads that need a plain Deployment, a Service, and no
chart-specific behaviour. That is exactly ntfy's shape, so it moved onto the shared chart with every
other app of its kind. The consequence recorded above about depending on a single-maintainer community
chart is retired with it. The chart is now the same one the rest of the estate already tracks through
Renovate, and the only version that has to be watched for ntfy itself is the upstream image tag. The
wrenix HelmRepository was removed from `sources/helm/` once nothing referenced it.

Alertmanager no longer posts to ntfy's built-in `alertmanager` template. Since 2026-06-18 the receiver
is a plain webhook to `/alerts?tpl=yes` with the title and message supplied as URL-encoded Go templates
in the query string, defined inline in the kube-prometheus-stack values ConfigMap. The change was made
to send a compact notification. The title renders status, alert name, and the number of alerts in the
group, and the message renders severity and the summary annotation, which is what fits on a phone
without opening the alert. `send_resolved: true` is unchanged, and the
`Watchdog`/`InfoInhibitor` sub-route still goes to `null`. Grafana's own unified alerting posts to the
same endpoint with its own title and message templates. The cost is that the format now lives in this
repository as a percent-encoded string rather than in the ntfy container. That is harder to read in
review, but it is the reason the format can be changed by a commit at all.

The decisions on running without authentication and without persistence are unchanged. They still rest
on the same reasoning: the service carries no public DNS record, its NetworkPolicy admits only Traefik,
the monitoring namespace, and flux-system, and it is reachable only over the overlay or the LAN.

---
status: accepted
date: 2026-06-14
---

# 0018. Add an internal cluster dashboard and router metrics

## Context

The cluster had grown to a handful of services spread across public and internal hostnames, with no single landing page that gathers them and shows their state at a glance. A dashboard would tie the services together and surface basic cluster health, but it had to fit the repository's invariant that the repository is the only way state reaches the cluster. A tool that keeps its own configuration in a database edited through a web UI would put live state outside Git and break that property. The Pi router had a related gap: it is the gateway, firewall, and DNS server, yet it exported no metrics, so it was the one piece of the network that never appeared in Grafana. Any monitoring added to it had to stay on the trusted side and never widen the router's exposure on the WAN or home interface.

## Decision

A [Homepage](https://gethomepage.dev) dashboard is deployed at `home.syslabs.dev`, internal-only and not routed through the Cloudflare tunnel. Its configuration is committed rather than edited at runtime, so the dashboard is reproducible from Git like every other workload. A read-only RBAC role backs the Kubernetes widgets, and `HOMEPAGE_ALLOWED_HOSTS` is set to the dashboard hostname so the service only answers on its own name. The service list is not hand-maintained: Homepage discovers entries from the cluster by reading `gethomepage.dev` annotations on each service's Traefik IngressRoute or native Ingress, so a route and its dashboard tile are defined in one place and cannot drift apart. The workload started as plain manifests and now ships as an `app-template` HelmRelease under the per-app pattern of [0066](0066-standardize-app-delivery-per-app-kustomizations.md).

The Pi router gains a node_exporter for host metrics, binding to the VLAN 20 address `10.20.0.1`, reachable from the cluster but never offered on the WAN or home interface, so no firewall change is needed to scrape it. Prometheus scrapes it as a static target, which brings the router into Grafana and onto the dashboard alongside the cluster. A WireGuard exporter for tunnel state was added beside it and removed with the move to the Tailscale overlay in [0023](0023-tailscale-overlay.md).

## Options considered

- Homepage with file and ConfigMap configuration, chosen. Its configuration lives in the repository, which fits the GitOps invariant, and it ships first-class widgets for Kubernetes and for the services already running.
- Homarr. It has a polished editor, but it stores its configuration in a database edited through its web UI, so the live dashboard would not be reproducible from Git. That conflicts directly with the invariant the rest of the cluster is built on.
- No dashboard, relying on bookmarks and Grafana alone. The lowest effort, but it leaves the services without a shared landing page and keeps the router invisible to monitoring.

## Consequences

The dashboard is reproducible from the repository like every other workload, and a read-only role keeps its cluster access narrow. Setting `HOMEPAGE_ALLOWED_HOSTS` and keeping it off the tunnel means it stays an internal surface reached over the Tailscale overlay or the LAN through split-horizon DNS. The router reports host metrics into Prometheus without any new inbound exposure, so it appears in Grafana and on the dashboard. The Pi wall-display kiosk deferred here was later built by [0054](0054-bar-display-grafana-kiosk-and-corrected-edid.md), which points the panel at an anonymous Grafana bar dashboard rather than at Homepage, because an unattended screen has no way to clear a login.

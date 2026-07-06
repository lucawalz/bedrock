---
status: accepted
date: 2026-06-14
---

# 0018. Add an internal cluster dashboard and router metrics

## Context

The cluster had grown to a handful of services spread across public and internal hostnames, with no single landing page that gathers them and shows their state at a glance. A dashboard would tie the services together and surface basic cluster health, but it had to fit the repository's invariant that the repository is the only way state reaches the cluster. A tool that keeps its own configuration in a database edited through a web UI would put live state outside Git and break that property.

The Pi router had a related gap. It is the gateway, firewall, DNS, and WireGuard hub, yet it exported no metrics, so it was the one piece of the network that never appeared in Grafana. Any monitoring added to it had to stay on the trusted side of the network and never widen the router's exposure on the WAN or home interface.

## Decision

A [Homepage](https://gethomepage.dev) dashboard is deployed at `home.syslabs.dev`, internal-only and not routed through the Cloudflare tunnel. It is deployed as plain manifests, with its configuration committed in a ConfigMap rather than edited at runtime, so the dashboard is reproducible from Git like every other workload. A read-only RBAC role backs the Kubernetes widgets, and `HOMEPAGE_ALLOWED_HOSTS` is set to the dashboard hostname so the service only answers on its own name. The service list is no longer hand-maintained in the ConfigMap; Homepage discovers entries from the cluster by reading `gethomepage.dev` annotations on each service's Traefik IngressRoute or native Ingress, so a route and its dashboard tile are defined in one place and cannot drift apart.

The Pi router gains a node_exporter for host metrics, binding to the VLAN 20 address `10.20.0.1`, reachable from the cluster but never offered on the WAN or home interface, so no firewall change is needed to scrape it. Prometheus scrapes it as a static target, which brings the router into Grafana and onto the dashboard alongside the cluster. A WireGuard exporter for tunnel state was initially added beside it and later removed with the move to the Tailscale overlay in [0023](0023-tailscale-overlay.md).

## Options considered

- Homepage with file and ConfigMap configuration, chosen. Its configuration lives in the repository, which fits the GitOps invariant, and it ships first-class widgets for Kubernetes and for the services already running.
- Homarr. It has a polished editor, but it stores its configuration in a database edited through its web UI, so the live dashboard would not be reproducible from Git and would drift from the repository. That conflicts directly with the invariant the rest of the cluster is built on.
- No dashboard, relying on bookmarks and Grafana alone. The lowest effort, but it leaves the services without a shared landing page and keeps the router invisible to monitoring.

## Consequences

The dashboard is reproducible from the repository like every other workload, and a read-only role keeps its cluster access narrow. Setting `HOMEPAGE_ALLOWED_HOSTS` and keeping it off the tunnel means it stays an internal surface reached over WireGuard or the LAN through split-horizon DNS. The router now reports host and tunnel metrics into Prometheus without any new inbound exposure, so it finally appears in Grafana and on the dashboard. A Pi wall-display kiosk, a cage session running Chromium pinned to the dashboard, is deferred until the physical screen is connected, and is left as future work rather than carried as unused configuration.

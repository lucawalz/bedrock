---
status: superseded by 0054
date: 2026-06-23
---

# 0051. Turn the router's bar display into a window into the cluster with Headlamp

## Context

[0050](0050-poe-switch-powers-the-router.md) added a PoE switch powering the Raspberry Pi router,
and the same build attached a 1280x400 HDMI bar panel to it. The panel should be more than a static
readout: a live graphical view of the cluster that is also a usable interactive desktop. The
router is the gateway and the most network-exposed host, so the view has to run somewhere else.

## Decision

Run Headlamp, a graphical Kubernetes UI, in-cluster as a Flux HelmRelease, the same shape as every
other dashboard here, exposed at `headlamp.syslabs.dev` through Traefik with Authentik forward-auth
([0008](0008-traefik-ingress.md), [0038](0038-authentik-sso-for-internal-dashboards.md)). It reaches
the cluster through a dedicated ServiceAccount bound to `cluster-admin`, a single-operator choice
weighed against a read-only `view` binding. The router holds no kubeconfig and no token.

The panel runs a kiosk Wayland session: greetd autologs an unprivileged `kiosk` user into labwc,
which opens Chromium in app mode at the dashboard URL and idles the output off after ten minutes.
labwc is chosen for its small footprint and written so the compositor is a one-line swap to sway,
with a tuigreet fallback for a manual login. Panel mode and EDID handling are settled at bring-up.

## Options considered

- Headlamp as a desktop application on the router with a read-only kubeconfig. Rejected: it is not
  packaged in nixpkgs, and a kubeconfig on the gateway is a worse blast radius than in-cluster.
- A Grafana kiosk on the panel. Rejected as redundant, since Grafana is already reached from a
  browser, and it shows metrics rather than the live cluster objects wanted here.
- A bare-framebuffer status renderer with no desktop. Rejected because the panel is also wanted as
  an interactive desktop, not a one-way readout.
- niri as the compositor. Rejected for now: on aarch64 it builds from source, its greetd autologin
  story is less settled, and it would add a flake input. labwc and sway cover the need without that.

## Consequences

The gateway holds no cluster credentials, but the dashboard is cluster-admin, so anyone past single
sign-on can manage the cluster, accepted for a single-operator lab. The resting view depends on the
cluster, Traefik, and Authentik being healthy, so a dark panel in an outage is an honest signal, and
running a browser on the gateway is added surface mitigated by the kiosk browser, the unprivileged
autologin user, no new ports, and the firewall ([0012](0012-bulletproof-router-hardening.md)).

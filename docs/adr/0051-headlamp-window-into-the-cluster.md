---
status: superseded by 0054
date: 2026-06-23
---

# 0051. Turn the router's bar display into a window into the cluster with Headlamp

> Superseded by [0054](0054-bar-display-grafana-kiosk-and-corrected-edid.md).

## Context

[0050](0050-poe-switch-powers-the-router.md) added a PoE switch that powers the Raspberry Pi
router, and the same build attached a 1280x400 HDMI bar panel to the router, driven from the PoE
HAT. The panel should be more than a static readout: a live graphical view of the cluster that is
also a usable, lightweight interactive desktop. Headlamp, a graphical Kubernetes UI, is the chosen
centerpiece, rather than a terminal tool or Grafana, which is already reached from a browser. The
router had no display stack and, by design, no Kubernetes credentials: it is the gateway, the most
network-exposed host, running DNS, DHCP, NAT, and the firewall.

Two questions followed. Where should Headlamp run, given that putting a kubeconfig on the gateway
widens the blast radius of that one box; and how should the panel present it without turning the
router into a full workstation.

## Decision

Run Headlamp in-cluster as a Flux HelmRelease, the same shape as every other dashboard here
(Grafana, Longhorn, Velero-UI, Homepage), exposed at `headlamp.syslabs.dev` through Traefik with
Authentik forward-auth ([0008](0008-traefik-ingress.md),
[0038](0038-authentik-sso-for-internal-dashboards.md)). It talks to the cluster through a dedicated
ServiceAccount bound to `cluster-admin`, giving full read-write management from the panel, with
Authentik single sign-on as the sole access gate. This is a single-operator homelab choice, weighed
against a read-only `view` binding and taken for management convenience. The router holds no
kubeconfig and no token; it only resolves and reaches the dashboard like any other internal service.

The panel runs a kiosk Wayland session: greetd autologs an unprivileged `kiosk` user into labwc,
which opens Chromium in app mode at the Headlamp URL and idles the output off through swayidle
after ten minutes, waking on input. labwc is chosen for its small footprint and is written so the
compositor is a one-line swap to sway; a manual operator login remains available through a tuigreet
fallback. The desktop is confined to the router host and adds nothing to the shared package set.
The exact panel mode, rotation, and EDID handling are settled during hardware bring-up once the
panel is cabled, with the output driven by `wlr-randr`.

## Options considered

- Headlamp as a desktop application on the router with a read-only kubeconfig. Rejected: Headlamp
  is not packaged in nixpkgs, so it would mean carrying a hand-built Electron app on the gateway,
  and a kubeconfig on disk there is a worse blast radius than an in-cluster ServiceAccount.
- A Grafana kiosk on the panel. Rejected as redundant, since Grafana is already reached from a
  browser, and it shows metrics rather than the live cluster objects wanted here.
- A bare-framebuffer status renderer with no desktop. Rejected because the panel is also wanted as
  an interactive desktop, not a one-way readout.
- niri as the compositor. Rejected for now: on aarch64 it builds from source, its greetd autologin
  story is less settled, and it would add a flake input. labwc and sway cover the need without that.

## Consequences

The gateway holds no cluster credentials, but the dashboard itself is cluster-admin: anyone who
passes Authentik single sign-on, or reaches an authenticated session at the panel, can manage the
cluster, with the Authentik gate as the sole control, accepted for a single-operator lab. The
credential stays in-cluster as the ServiceAccount, not a kubeconfig on the router, so the gateway's
blast radius is unchanged. Headlamp is patched by bumping its chart in Flux, the same motion as
every other dashboard, rather than by rebuilding the router.

The resting view depends on the cluster, Traefik, and Authentik being healthy; if the cluster is
down the panel goes dark, which is an honest signal for a window into the cluster rather than a
failure to hide. Running a browser and a compositor on the gateway is real added surface, mitigated
by the unprivileged autologin user, the kiosk-mode browser, no new inbound ports, and egress
already constrained by the router's own AdGuard and firewall
([0012](0012-bulletproof-router-hardening.md), [0017](0017-defense-in-depth-baseline.md)). Host
secrets stay in agenix and none of this puts a credential on the router
([0007](0007-agenix-sops-secrets.md)). The panel joins the internal dashboards recorded in
[0018](0018-internal-dashboard-and-router-metrics.md). One caveat carries into bring-up: cheap HDMI
driver boards may ignore DPMS and keep the backlight lit, so the idle-off may blank the signal
without cutting the light.

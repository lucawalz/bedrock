---
status: accepted
date: 2026-06-23
---

# 0054. Drive the router bar display with an anonymous Grafana kiosk and a corrected panel EDID

## Context

[0051](0051-headlamp-window-into-the-cluster.md) pointed the router's 1280x400 bar panel at
`headlamp.syslabs.dev`, which sits behind Authentik forward-auth
([0038](0038-authentik-sso-for-internal-dashboards.md)). The panel is a wall display with no
keyboard or mouse, so an unattended session has no way to clear the Authentik login and rests
forever on the sign-in page rather than on the cluster view it was built to show.

A second problem surfaced during hardware bring-up. The desktop session pillarboxed, leaving black
bars down both sides, because the Wisecoco panel's factory EDID carries a malformed 1280x400
preferred timing that the kernel drops. With no valid native mode advertised, the desktop fell back
to a synthesized custom mode the panel could not lock, while the boot console filled the panel only
by selecting a standard mode that the panel's own scaler stretches to fit. Neither path gave a
true 1:1 1280x400 picture.

## Decision

Point the kiosk at an anonymous, read-only Grafana dashboard built for the 1280x400 bar. Grafana is
internal only and is not published on the Cloudflare tunnel
([0014](0014-declarative-minimal-cloudflare-exposure.md)), so enabling anonymous Viewer access
exposes read-only dashboards on the LAN and the tailnet alone, with no login to clear. The bar
dashboard shows live cluster status drawn from Prometheus, the same source the existing dashboards
use ([0018](0018-internal-dashboard-and-router-metrics.md)).

Remove Headlamp entirely. It existed only to drive this panel, so with the panel moved to Grafana it
has no remaining purpose, and dropping it also retires its in-cluster ServiceAccount and its
`cluster-admin` token. That removes one standing credential, and it removes the one with the widest
reach from the host that is most network-exposed.

Fix the panel mode by feeding the kernel a corrected EDID rather than a synthesized custom mode.
The panel's native timing was recovered as a 41.5 MHz pixel clock with an htotal of 1441 and a
vtotal of 480. A corrected EDID carrying that timing is generated through the `hardware.display`
module, and the now-valid 1280x400 mode is selected for the output, so the panel locks its real
native mode and fills edge to edge.

The kiosk session architecture from [0051](0051-headlamp-window-into-the-cluster.md) carries
forward unchanged: greetd autologs the unprivileged `kiosk` user into labwc, which opens Chromium in
app mode at the dashboard URL. Only the display target and the mode handling change.

## Options considered

- Keep Headlamp but bypass Authentik for the router's source IP. Rejected: Traefik does not
  reliably see the real client IP without `externalTrafficPolicy: Local`, and the result is either
  an unauthenticated `cluster-admin` UI reachable from the gateway or a set of extra moving parts to
  scope the exception narrowly. Neither earns its place against a read-only Grafana view.
- A dedicated custom status page rendered for the bar. Rejected: it is more to build and maintain
  than a Grafana dashboard, which is already backed by Prometheus and styled with the existing
  panel library.

## Consequences

The panel shows live cluster status with no interactive login to clear, which is what an unattended
wall display needs. The EDID change takes effect at boot, so the router needs a reboot to pick it
up. The corrected timing still has to be confirmed on the panel during bring-up; if it will not
lock, the documented fallback is to drive an advertised 1280x720 mode, which matches the panel's
width 1:1 and asks the scaler only for vertical compression rather than a two-axis stretch. Removing
Headlamp leaves one fewer standing cluster credential, and the most network-exposed host no longer
has a path to a `cluster-admin` token at all. This supersedes the display-target choice in
[0051](0051-headlamp-window-into-the-cluster.md); the kiosk session it describes is retained.

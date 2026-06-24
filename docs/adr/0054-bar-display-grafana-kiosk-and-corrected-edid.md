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

Fix the panel mode by overriding the panel's EDID with a corrected one. The native timing is a
41.5 MHz pixel clock at 1280x400, but the factory EDID encodes it with an odd horizontal total of
1441. The vc4 HDMI pipeline rejects an odd horizontal total as an illegal timing and prunes the
mode, so the kernel never advertises 1280x400 and the session falls back to a mode the panel's
scaler stretches or pillarboxes. The corrected EDID carries the same 41.5 MHz clock with the
blanking widened to an even horizontal total of 1442, which the kernel accepts and marks preferred.
With that mode advertised the board locks the panel's real native timing and fills edge to edge with
no bars and no stretch.

The override is applied after boot rather than from the bootloader. A oneshot service writes the
corrected EDID to the connector's `edid_override` and forces a re-detect before greetd starts, so
labwc reads the corrected mode list when it opens the output. An earlier attempt to deliver the EDID
from the initramfs through `boot.initrd.prepend` left the router in emergency mode and was abandoned.
The panel's only consumer is the desktop session, which starts well after boot, so a post-boot
override carries no risk to the gateway: a failure degrades the picture and never the boot.

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
wall display needs. The corrected timing was confirmed on the panel during bring-up: at 41.5 MHz
with an even horizontal total the board renders a true 1:1 1280x400 picture with no bars. The
override runs from a service ordered before greetd, so it is re-applied on every session start and
holds without a bootloader or kernel change; the router still needs one reboot to activate the
system generation that carries the service. Removing Headlamp leaves one fewer standing cluster
credential, and the most network-exposed host no longer has a path to a `cluster-admin` token at
all. This supersedes the display-target choice in
[0051](0051-headlamp-window-into-the-cluster.md); the kiosk session it describes is retained.

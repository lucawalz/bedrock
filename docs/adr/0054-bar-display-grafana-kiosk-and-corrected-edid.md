---
status: accepted, anonymous access replaced by a public dashboard link
date: 2026-06-23
---

# 0054. Drive the router bar display with an anonymous Grafana kiosk and a corrected panel EDID

## Context

[0051](0051-headlamp-window-into-the-cluster.md) pointed the router's 1280x400 bar panel at
`headlamp.syslabs.dev`, which sits behind Authentik forward-auth
([0038](0038-authentik-sso-for-internal-dashboards.md)). The panel is a wall display with no
keyboard, so an unattended session has no way to clear the login and rests on the sign-in page.
Bring-up added a second problem: the desktop session pillarboxed, and the boot console filled the
panel only through the panel's own scaler, so neither path gave a true 1:1 picture.

## Decision

Point the kiosk at an anonymous, read-only Grafana dashboard built for the bar. Grafana is internal
only and is not published on the Cloudflare tunnel
([0014](0014-declarative-minimal-cloudflare-exposure.md)), so anonymous Viewer access exposes
read-only dashboards on the LAN and the tailnet alone, with no login to clear.

Remove Headlamp entirely. It existed only to drive this panel, so it has no remaining purpose, and
dropping it retires its in-cluster ServiceAccount and `cluster-admin` token, taking the credential
with the widest reach off the host that is most network-exposed. The kiosk session from
[0051](0051-headlamp-window-into-the-cluster.md) carries forward unchanged.

Fix the panel mode by overriding the panel's EDID. The native timing is a 41.5 MHz pixel clock at
1280x400, but the factory EDID encodes an odd horizontal total of 1441, which the vc4 HDMI pipeline
rejects as illegal and prunes, so the kernel never advertises the native mode. The corrected EDID
keeps the clock and widens the blanking to an even total of 1442, which the kernel accepts and marks
preferred. A oneshot service applies it before greetd starts rather than the initramfs, which was
tried first and left the router in emergency mode; after boot a failure degrades the picture only.

## Options considered

- Keep Headlamp but bypass Authentik for the router's source IP. Rejected: Traefik does not reliably
  see the real client IP without `externalTrafficPolicy: Local`, so the result is either an
  unauthenticated `cluster-admin` UI on the gateway or extra parts to scope the exception narrowly.
- A dedicated custom status page rendered for the bar. Rejected: more to build and maintain than a
  Grafana dashboard already backed by Prometheus and the existing panel library.

## Consequences

The panel shows live cluster status with no interactive login to clear, and the corrected timing was
confirmed on the panel: at 41.5 MHz with an even horizontal total the board renders a true 1:1
1280x400 picture with no bars, re-applied on every session start without a bootloader change.
Removing Headlamp leaves the most network-exposed host with no path to a `cluster-admin` token.
This supersedes the display target in [0051](0051-headlamp-window-into-the-cluster.md) alone; the
kiosk session it describes is retained.

## Update 2026-07-25

The EDID half of this record still describes what runs; the kiosk half does not. Anonymous Grafana
access is gone, `auth.anonymous.enabled` is `false`, and with it removed the panel reproduced the
exact failure that moved it off Headlamp. The panel is now driven by a Grafana public dashboard
whose link is held in an agenix secret readable only by the `kiosk` user, so rotating it is a re-key
rather than a configuration edit. The reasoning holds, because a wall display with no input device
cannot complete an interactive login, but the scope narrows: anonymous Viewer opened every
dashboard, while a public link opens one and its unguessable token is the only credential, which is
why the URL is treated as a secret rather than committed in the clear.

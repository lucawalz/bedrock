---
status: accepted
date: 2026-06-22
---

# 0050. Replace the layer-2 switch with a PoE model that powers the router

## Context

The zoned network in [0015](0015-zoned-network-on-a-nixos-router.md) and [0016](0016-concrete-zoned-ip-scheme.md) put a TP-Link TL-SG108E in front of the Raspberry Pi router as a plain layer-2 VLAN tagger. The Pi reaches everything over a single trunk cable: the home LAN untagged on the native VLAN to the Speedport, VLAN 20 tagged for the cluster, and VLAN 30 tagged for the DMZ. Two things about that switch were unsatisfying. The Pi drew its power from a separate USB-C brick, so the router depended on two cables and two power sources where one would do. And the switch took its management address from the Speedport over DHCP, which these Easy Smart switches renew unreliably; when the lease lapsed the switch fell off the network and its web UI became unreachable.

The physical port assignment was also never written down. The repository documented the IP scheme and the firewall zones but not which switch port carried which device, so a rewire had nothing to check against.

## Decision

Replace the TL-SG108E with its PoE sibling, the TP-Link TL-SG108PE, and power the Pi over the trunk cable it already uses. The PE has four 802.3af/at PoE+ ports on ports 1 to 4, up to 30 W each within a 64 W budget. The Pi carries a Waveshare PoE+ HAT that draws around 20 W with a small status screen on its USB-A output, well inside a single port's allowance. The layer-2 tagging is unchanged from [0016](0016-concrete-zoned-ip-scheme.md); only the hardware and the cabling around power change.

The switch takes a static management address, `192.168.2.212` on the home LAN with gateway `192.168.2.1`, so it no longer depends on the Speedport renewing a lease. Its configuration persists to flash on apply, and an off-switch backup file is kept for a one-shot restore after a factory reset.

The port map is now recorded:

| Port | Member | Tagging |
|------|--------|---------|
| 1 | Speedport uplink, home LAN | untagged VLAN 1 |
| 2 | Pi router trunk, PoE source | untagged VLAN 1, tagged VLAN 20 and 30 |
| 3 to 5 | spare | untagged VLAN 1 |
| 6 | master | untagged VLAN 20, PVID 20 |
| 7 | worker-1 | untagged VLAN 20, PVID 20 |
| 8 | worker-2 | untagged VLAN 20, PVID 20 |

## Options considered

- Keep the TL-SG108E and leave the Pi on its USB-C brick. Rejected: it keeps the second power cable and does nothing about the management address falling off DHCP.
- Restore the old switch's configuration file onto the new one. Rejected: the E and PE are different models and the binary config does not transfer, so the VLANs were re-entered by hand.
- Keep DHCP for the switch and reserve the address on the Speedport. Workable, but it still leans on the switch renewing a lease, which is the behaviour that failed before. A static address removes the dependency outright.

## Consequences

The router runs from one cable, drawing power and all three VLANs over the same link, and the switch sits at a fixed address that survives a Speedport reboot. The port map is documented here, so the next rewire has a reference. The 64 W PoE budget is shared across ports 1 to 4, which bounds any future powered devices such as an access point or camera. This supersedes the TL-SG108E hardware named in [0015](0015-zoned-network-on-a-nixos-router.md) and [0016](0016-concrete-zoned-ip-scheme.md); the router-on-a-stick topology and the IP scheme they describe are unchanged. The cutover dropped the cluster for the few minutes the trunk was unplugged, after which the nodes rejoined on their VLAN 20 addresses and the control plane recovered on its own.

---
status: accepted
date: 2026-06-13
---

# 0016. Adopt a concrete zoned IP scheme

## Context

[0015](0015-zoned-network-on-a-nixos-router.md) set the direction toward a zoned network on the NixOS router but deferred the concrete IP-range and zone plan, leaving a follow-up record owed once the scheme was settled. This is that record. The cluster had grown up on `192.168.20.0/24`, a flat DMZ that conflated trusted admin surfaces with public-facing workloads, and the addressing carried no signal about which zone a host belonged to.

The scheme also had to avoid collisions. The `10.0.0.0/24` default is the most common range in consumer gear and cloud defaults, and the burst nodes ride a WireGuard tunnel from Hetzner, so an overlap between the home addressing and a cloud network or another VPN would silently break routing across that tunnel.

## Decision

The network uses three managed zones plus the unmanaged home LAN, with a mnemonic that ties the 802.1Q VLAN id to the second octet:

- Servers and cluster, VLAN 20, `10.20.0.0/24`. Router `10.20.0.1`, master `10.20.0.10`, worker-1 `10.20.0.11`, worker-2 `10.20.0.12`, the MetalLB VIP `10.20.0.50`, and the kea DHCP pool `10.20.0.100` to `10.20.0.200`.
- DMZ, VLAN 30, `10.30.0.0/24`. Router `10.30.0.1`. The zone is defined but unpopulated, reserved for any genuinely public-facing host.
- WireGuard admin and burst overlay, `10.100.0.0/24`. Pi hub `10.100.0.1`, admin Mac peer `10.100.0.2`, and burst nodes that receive dynamic addresses.
- Home LAN, `192.168.2.0/24`, behind the Telekom Speedport and left unmanaged.

The router is the single inter-zone gateway and enforces default-deny between zones. The cluster zone and the WireGuard overlay are trusted; the DMZ is untrusted and may reach only the internet, with its traffic toward the cluster and the home LAN dropped, and it takes DNS and DHCP from the router alone. Adding a real DMZ host later means setting a switch port to untagged VLAN 30 with PVID 30 and tagging VLAN 30 on the Pi trunk port.

## Options considered

- Zone-encoding scheme under `10.0.0.0/8` with the VLAN id as the second octet, chosen. The address of a host names its zone at a glance, and the wider private block leaves room for more zones without renumbering.
- Keep `192.168.20.0/24` for the cluster and graft new zones onto adjacent `192.168.x` ranges. No renumbering, but the addressing stays mute about zones and the narrow `192.168.0.0/16` neighbourhood is crowded with consumer defaults.
- Stay on `10.0.0.0/24`. Familiar, but it is the single most common default range and risks colliding with a cloud network or another VPN, which matters because the burst nodes route across a tunnel.

## Consequences

The cluster was renumbered from `192.168.20.0/24` to `10.20.0.0/24`, which is not a free change. It required a coordinated migration that moved the router first and then the nodes, and because the cluster runs K3s on embedded etcd, the node-address change forced an etcd cluster-reset to bring the control plane back up on the new addresses. With that done, every host's address now names its zone, the ranges stay clear of common defaults so the burst tunnel routes cleanly, and the firewall in [0012](0012-bulletproof-router-hardening.md) has concrete zones to enforce default-deny between. This supersedes the addressing in [0004](0004-dmz-vlan-segmentation.md) and settles the plan deferred by [0015](0015-zoned-network-on-a-nixos-router.md).

---
status: accepted
date: 2026-11-07
---

# 0002. Declare every host with NixOS flakes

## Context

The estate is four machines: three Lenovo ThinkCentre m920q nodes and a Raspberry Pi that is the router, gateway and DNS. A host configured by hand drifts from anything written down and cannot be rebuilt from the repository.

## Decision

- Every host is a NixOS configuration in `flake.nix`. The cluster nodes are generated from `lib/inventory.nix`, which holds each node's role, address and MAC, and the server's tailnet identity. Adding a node is an inventory entry and an optional host directory, plus its agenix entries in `secrets/secrets.nix`, its own Tailscale auth key, and its host key added to the recipients of `k3s-token.age`. Disks are declared with disko and host secrets with agenix.
- The router is NixOS on the Pi (`modules/router`). It runs the nftables firewall, kea DHCP with reservations by MAC, AdGuard Home DNS, the Tailscale subnet router for `10.20.0.0/24`, the bar panel kiosk and the deadman receiver for the Alertmanager Watchdog.
- The network is zoned. VLAN 20 (`10.20.0.0/24`) holds the servers. VLAN 30 (`10.30.0.0/24`) is a DMZ that the firewall denies towards the cluster and the home LAN. From the home LAN the router forwards nothing into VLAN 20 except the service VIP `10.20.0.50` on 80 and 443.
- AdGuard answers every `*.syslabs.dev` name with the service VIP through one wildcard rewrite, so a new internal host needs no DNS change.
- Hosts are changed with `nixos-rebuild` over SSH. Admins reach VLAN 20 through the Pi's subnet route, and every cluster node also joins the tailnet as its own `tag:cluster` device, so the nodes stay reachable when the Pi is not.
- The Pi has no TPM and stays unencrypted. It holds only its own tailnet identity and agenix secrets (AdGuard admin, Wi-Fi, kiosk URL), bounded by Tailscale key expiry and its own `tag:router` tag, which the policy treats separately from `tag:cluster`. The kiosk session offers no terminal or launcher.

## Consequences

- A host is rebuilt from the flake and its agenix secrets; nothing on its disk is precious apart from Longhorn replicas and the k3s datastore.
- A router rebuild that restarts tailscaled cuts any session that runs through the subnet route, so router changes are applied through a node's own tailnet address.
- Firmware sits outside Nix and is patched by hand: `rpi-eeprom` on the Pi and the BIOS on the nodes.

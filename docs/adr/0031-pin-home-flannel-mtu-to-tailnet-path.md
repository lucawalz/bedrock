---
status: accepted
date: 2026-06-17
---

# 0031. Pin the home flannel MTU to the tailnet path MTU

## Context

Burst nodes are Hetzner machines that join the home cluster over Tailscale. They set `flannel-iface: tailscale0` so flannel derives its VXLAN MTU from the tunnel: `tailscale0` is 1280, less the 50-byte VXLAN header gives a flannel MTU of 1230. The tailnet leg between a home node and a burst node therefore carries a path MTU of 1280.

The home nodes (master, worker-1, worker-2) are not tailnet members and have no `tailscale0`. Their flannel.1 derives its MTU from the 1500-byte LAN, settling at the flannel default of 1450. The two ends of the overlay disagree: home flannel emits VXLAN frames sized for 1450 while the tailnet leg only carries 1280.

Cross-node pod packets larger than roughly 1200 bytes set the don't-fragment bit and exceed the 1280 tunnel, so they are dropped with fragmentation-needed on the tailnet leg. The drop is silent to the workload. This black-holed pod-to-pod and pod-to-CoreDNS traffic on the burst node and crashed pod-networked workloads there, including Falco and Longhorn.

## Decision

Pin the home flannel MTU to 1230 so every node's overlay agrees at the tailnet path MTU. k3s exposes no first-class flannel-MTU option, so the shared k3s module deploys a flannel net-conf at `/etc/k3s/flannel-net-conf.json` carrying the cluster pod CIDR `10.42.0.0/16`, the vxlan backend, and `MTU: 1230`, and points k3s at it with `--flannel-conf`. The override keeps k3s's own pod CIDR and vxlan backend, with the same VNI and UDP 8472 port, so only the MTU changes.

The override lives in `common.nix`, which both the server and agent modules import, so master and both workers receive it. The burst node module does not import `common.nix`, so the burst node is untouched and keeps deriving its 1230 from `tailscale0`.

## Options considered

- Deploy a flannel net-conf override pinning MTU 1230 through the shared k3s module, chosen. It is the single place that reaches all home nodes, it changes only the MTU while preserving the pod CIDR and backend, and it lands the same 1230 the burst node already uses.
- Set `flannel-iface: tailscale0` on the home nodes as well, rejected. The home nodes are not tailnet members and have no `tailscale0`, so flannel would have no interface to bind and the overlay would break.
- Add static routes or push the correction through the Pi router, rejected. The underlay already routes correctly via the Pi; the only fault is the MTU mismatch, which routing changes do not address.

## Consequences

All home nodes carry a flannel.1 MTU of 1230, matching the burst node and the tailnet path, so cross-node pod packets no longer exceed the tunnel and pod-networked workloads on burst nodes stop being black-holed. Home-to-home pod traffic now also runs at 1230 rather than 1450; the lower MTU costs a small amount of per-packet efficiency on the LAN but keeps a single overlay MTU across the whole cluster, which is simpler than a per-node split and removes the failure mode entirely. The net-conf file becomes the source of truth for the home overlay's pod CIDR and backend, so any future change to either must be made there as well as in k3s.

A live measurement this session confirmed the pin is exact: 1230 plus the 50-byte VXLAN header is 1280, the `tailscale0` path MTU, so the overlay now fits its worst leg with nothing to spare.

## Follow-up

This pin is an interim mitigation, not the architectural fix. The home-to-home tax from 1450 down to 1230 is unavoidable within a single flannel overlay: flannel carries one MTU per overlay and has no per-peer MTU, so the overlay must fit its worst path, the 1280 tailnet tunnel to the burst nodes.

The root-cause fix is topological: stop stretching one flat flannel overlay across the VPN tunnel, for example by giving the burst nodes their own cluster or overlay joined through a gateway, so home-to-home traffic keeps its native 1450 and only the cross-site leg pays the tunnel cost. That work is deferred to the planned CAPH v1.2 and CAPI upgrade tracked in ADR 0030.

Raising the Tailscale tunnel MTU was considered and rejected. A larger tunnel would recover the marginal efficiency but sacrifices Tailscale's DERP-fallback robustness, which is not a trade worth making for an overlay this small.

---
status: accepted, premise superseded by 0074
date: 2026-06-17
---

# 0031. Pin the home flannel MTU to the tailnet path MTU

## Context

Burst nodes are Hetzner machines that join the home cluster over Tailscale. They set `flannel-iface: tailscale0` so flannel derives its VXLAN MTU from the tunnel: `tailscale0` is 1280, and flannel subtracts the 50-byte VXLAN header, so the overlay device settles at 1230 and the tailnet leg carries a path MTU of 1280.

The home nodes were not tailnet members at the time and had no `tailscale0`, so their flannel device derived its MTU from the 1500-byte LAN and settled at the flannel default of 1450. The two ends of the overlay disagreed: home flannel emitted VXLAN frames sized for 1450 while the tailnet leg only carried 1280. Cross-node pod packets larger than roughly 1200 bytes set the don't-fragment bit and exceeded the tunnel, so they were dropped with fragmentation-needed on the tailnet leg. The drop was silent to the workload, which black-holed pod-to-pod and pod-to-CoreDNS traffic on the burst node and crashed pod-networked workloads there.

## Decision

Pin the home flannel overlay to 1230 so every node's overlay agrees at the tailnet path MTU. k3s exposes no first-class flannel-MTU option, so the shared k3s module deploys a flannel net-conf carrying the cluster pod CIDR, the vxlan backend, and an MTU of 1280, and points k3s at it with `--flannel-conf`. The net-conf field is the outer encapsulated-packet size, so it has to carry 1280 for the device to land on 1230; an earlier 1230 in the field produced a 1180 device. The override lives in the module both the server and agent import, so every home node receives it, and it keeps k3s's own pod CIDR, vxlan backend, VNI, and port so only the MTU changes. [0074](0074-home-nodes-on-the-tailnet.md) later made the home nodes tailnet members, which removes the premise above but not the pin: a `tailscale0`-bound flannel derives exactly the same 1230, and the file is still why the overlay reads as it does.

## Options considered

- Deploy a flannel net-conf override through the shared k3s module, setting the outer MTU to 1280 so the overlay device settles at 1230, chosen. It is the single place that reaches all home nodes, it changes only the MTU while preserving the pod CIDR and backend, and it lands the same 1230 the burst node already uses.
- Set `flannel-iface: tailscale0` on the home nodes as well, rejected at the time because they were not tailnet members and had no interface for flannel to bind. [0074](0074-home-nodes-on-the-tailnet.md) reverses that premise and adopts the binding.
- Add static routes or push the correction through the Pi router, rejected. The underlay already routes correctly, and the only fault is the MTU mismatch, which routing changes do not address.

## Consequences

All nodes carry a flannel MTU of 1230, matching the tailnet path, so cross-node pod packets no longer exceed the tunnel. Home-to-home pod traffic runs at 1230 rather than 1450, which costs a small amount of per-packet efficiency but keeps a single overlay MTU across the whole cluster and removes the failure mode entirely. The net-conf file is the source of truth for the home overlay's pod CIDR and backend, so a future change to either has to be made there as well as in k3s. Applying a changed MTU requires recreating the flannel device, since a k3s restart reuses the persistent vxlan interface at its old MTU; the current procedure is in the disaster-recovery runbook.

The home-to-home tax is permanent rather than interim. Flannel carries one MTU per overlay and has no per-peer MTU, so the overlay must fit its worst path. The topological alternative, giving the burst nodes their own cluster or overlay joined through a gateway so only the cross-site leg pays the tunnel cost, was weighed again in [0074](0074-home-nodes-on-the-tailnet.md) and rejected in favour of one flat tailnet overlay. Raising the Tailscale tunnel MTU was also rejected: a larger tunnel would recover the marginal efficiency but sacrifices DERP-fallback robustness, which is not a trade worth making for an overlay this small.

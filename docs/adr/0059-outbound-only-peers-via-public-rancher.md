---
status: superseded by 0063
date: 2026-07-06
---

# 0059. Outbound-only peers via public Rancher

## Context

Cross-region peer clusters ran K3s on Hetzner, provisioned by Cluster API and imported into Rancher through Turtles. Each peer needed two things from the estate: management from the Rancher hub, and GitOps reconciliation of its own workloads. Neither should require an inbound path back into the home cluster, because home sits behind a residential connection with no stable public ingress and every open port toward it widens the attack surface of the whole lab.

An earlier direction joined peers to the home tailnet to solve management. It coupled peer bring-up to Tailscale and to MagicDNS resolving at boot, so a peer could not come up cleanly until the overlay was established, and it repeatedly failed at GitOps reconciliation, because the peer secret store would have needed home's own decryption key to read the encrypted manifests. That meant handing a remote cluster the key that protects the entire estate. The direction was abandoned and the Tailscale authkey injection was removed from the cluster-class so new peers no longer attempt to join the overlay. Two facts constrained the replacement. Rancher was already reachable from the public internet through the existing Cloudflare tunnel at `rancher.syslabs.dev`, fronted by Cloudflare Access, so the hub had a stable name a peer could dial from anywhere. And a Rancher-imported cluster is managed through an outbound tunnel: the `cattle-cluster-agent` on the peer dials the hub and registers, after which administrative traffic returns down that same tunnel, so the hub never has to reach into the peer's apiserver.

## Decision

Peers are outbound-only and do not join the tailnet. Every dependency a peer needs is something it reaches out to, never something that reaches in. Rancher stays exposed publicly through the Cloudflare tunnel, protected by Cloudflare Access with multi-factor authentication on the human-facing paths, and a second, narrow Access application bypasses only the agent registration paths so a peer's agent can dial out and register without a human credential. The dashboard and the cluster-proxy stay behind that gate.

Turtles auto-imports each peer. On import the agent establishes an outbound tunnel to Rancher, administrative access returns through that reverse tunnel, and GitOps reconciliation is likewise satisfied by what the peer pulls rather than by home pushing into it. The peer control-plane load balancer remains public, because the home cluster's Cluster API lifecycle still reaches it to provision and manage the cluster; firewalling that load balancer to home egress is a separate perimeter change tracked in a later record.

## Options considered

- Tailnet-joined peers managed over the overlay. The abandoned direction. It broke GitOps reconciliation because the peer secret store would have required home's decryption key, and it coupled peer health to both the overlay and the home cluster, buying reachability the outbound tunnel already provides.
- Hub Flux driving peers through a remote kubeconfig. It keeps a single control point but couples peer health to the home cluster and needs continuous inbound reachability to each peer's apiserver, so a peer would stop reconciling whenever home was unreachable, which is the exact dependency this record removes.
- Outbound-only peers reaching public Rancher with an agent-path Access bypass, chosen. Registration, management, and reconciliation are all initiated outward, so a peer needs no inbound path and depends on nothing at home being up. The cost is a public Rancher endpoint, which Cloudflare Access already fronts.

## Consequences

A peer needs no inbound path and survives home being unreachable: it registers outward, is managed down its own tunnel, and reconciles what it pulls. The registration bypass was a required prerequisite before a peer could register, since the registration paths otherwise sit behind multi-factor authentication that an unattended agent cannot satisfy, and the failure presents as a 403.

The peer estate this record served is gone. [0063](0063-return-to-single-region.md) returned the homelab to a single region and the last peer infrastructure went with the Hetzner account under [0081](0081-retire-the-hetzner-account.md). The registration bypass outlived its consumer and was removed on 2026-09-12, so `rancher.syslabs.dev` is now behind forward auth on every path; the reasoning and the case to watch on a future import are recorded in [0014](0014-declarative-minimal-cloudflare-exposure.md). The public control-plane load balancer and the perimeter gap this record left open went with the peers themselves.

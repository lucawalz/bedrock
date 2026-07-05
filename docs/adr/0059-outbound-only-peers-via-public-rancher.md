---
status: accepted
date: 2026-07-06
---

# 0059. Outbound-only peers via public Rancher

## Context

Cross-region peer clusters run K3s on Hetzner, provisioned by CAPI and the Cluster API Provider Hetzner and imported into Rancher through Turtles. Each peer needs two things from the estate: management from the Rancher hub, and GitOps reconciliation of its own workloads. Neither should require an inbound path back into the home cluster, because home sits behind a residential connection with no stable public ingress and every open port toward it widens the attack surface of the whole lab.

An earlier direction joined peers to the home tailnet to solve management. It coupled peer bring-up to Tailscale and to MagicDNS resolving at boot, so a peer could not come up cleanly until the overlay was established and names resolved. It also repeatedly failed at the point of GitOps reconciliation, because the peer secret store would have needed home's own decryption key to read the encrypted manifests, which meant handing a remote cluster the key that protects the entire estate. That direction was abandoned and reset; a tag marks the abandoned state, and the Tailscale authkey injection was removed from the cluster-class so new peers no longer attempt to join the overlay.

Two facts constrain the replacement. Rancher is already reachable from the public internet through the existing Cloudflare tunnel at `rancher.syslabs.dev`, fronted by Cloudflare Access, so the hub has a stable name that a peer can dial from anywhere. And a Rancher-imported cluster is managed through an outbound tunnel: the `cattle-cluster-agent` on the peer dials the hub and registers, after which administrative traffic returns down that same tunnel, so the hub never has to reach into the peer's apiserver to drive it.

## Decision

Peers are outbound-only and do not join the tailnet. Every dependency a peer needs is something it reaches out to, never something that reaches in.

Rancher stays exposed publicly through the Cloudflare tunnel at `rancher.syslabs.dev`, protected by Cloudflare Access with multi-factor authentication on the human-facing paths. A second, narrow Access application bypasses only the agent registration paths, `/ping`, `/healthz`, `/v3/connect*`, and `/v3/import*`, so a peer's `cattle-cluster-agent` can dial out and register without a human credential, while the dashboard and the cluster-proxy stay behind MFA. The bypass is scoped to exactly the paths registration uses and nothing more.

Turtles auto-imports each peer. On import the agent establishes an outbound tunnel to Rancher, and administrative `kubectl` returns through that Rancher reverse tunnel, so no inbound apiserver access is needed from outside the peer. GitOps reconciliation is likewise satisfied by what the peer pulls, not by home pushing into it.

The peer control-plane load balancer remains public, because the home cluster's CAPI lifecycle still reaches it to provision and manage the cluster. Firewalling that load balancer to home egress is a separate perimeter change tracked in a later record.

## Options considered

- Tailnet-joined peers managed over the overlay. This was the abandoned direction. It broke GitOps reconciliation because the peer secret store would have required home's decryption key, and it coupled peer health to both the Tailscale overlay and the home cluster, so a peer could not stand on its own. The overlay bought reachability the outbound tunnel already provides without that coupling.
- Hub Flux driving peers through a remote kubeconfig. Letting home's Flux reconcile each peer over a stored kubeconfig keeps a single control point, but it couples peer health to the home cluster and needs continuous inbound reachability to each peer's apiserver. A peer would stop reconciling whenever home was unreachable, which is the exact dependency this record is trying to remove.
- Outbound-only peers reaching public Rancher with an agent-path Access bypass. This is the chosen option. Registration, management, and reconciliation are all things the peer initiates outward, so a peer needs no inbound path and depends on nothing at home being up. The cost is a public Rancher endpoint, which Cloudflare Access with MFA on the human paths already fronts.

## Consequences

A peer needs no inbound path and survives home being unreachable: it registers outward, is managed down its own tunnel, and reconciles what it pulls, so an outage at home does not stop a peer from running. Management and GitOps both ride outbound connections that the peer owns.

The Cloudflare Access agent-path bypass is a required prerequisite before a peer can register. Without it the registration paths sit behind MFA, which an unattended agent cannot satisfy, and the failure presents as a 403 on `/ping`. The bypass must exist before a peer is brought up, and it is scoped to the registration paths alone so the dashboard and cluster-proxy keep their MFA gate.

The public control-plane load balancer still needs a firewall perimeter. It stays reachable for the home cluster's CAPI lifecycle today, but leaving it open to the internet is a gap, and closing it to home egress is tracked separately rather than resolved here.

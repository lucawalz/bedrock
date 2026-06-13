# Architecture decision records

These records capture the significant architecture decisions behind the bedrock homelab and the workloads that run on it. They follow the MADR format: a short context, the decision, the options weighed, and the consequences. Each record's status reflects whether the decision is shipped (accepted), accepted but not yet implemented, still open (proposed), or no longer in force (rejected, or superseded by a later record).

- [0001. Run the cluster as K3s on NixOS hosts](0001-k3s-on-nixos.md) (accepted)
- [0002. Declare hosts with NixOS flakes, reconcile the cluster with Flux](0002-nixos-flakes-flux-gitops.md) (accepted)
- [0003. Run the edge router on NixOS instead of OPNsense](0003-nixos-router-over-opnsense.md) (accepted)
- [0004. Isolate the cluster on a VLAN 20 DMZ](0004-dmz-vlan-segmentation.md) (accepted, addressing superseded by 0016)
- [0005. Use Longhorn for replicated block storage](0005-longhorn-storage.md) (accepted)
- [0006. Issue certificates with cert-manager over Cloudflare DNS-01](0006-cert-manager-dns01.md) (accepted)
- [0007. Split secrets between agenix for hosts and SOPS for the cluster](0007-agenix-sops-secrets.md) (accepted)
- [0008. Use Traefik as the cluster ingress](0008-traefik-ingress.md) (accepted)
- [0009. Back up the cluster with Velero to Hetzner object storage](0009-velero-backups.md) (accepted)
- [0010. Self-host a WireGuard overlay to replace ZeroTier](0010-wireguard-overlay.md) (accepted)
- [0011. Own the edge with a port-forward instead of a Cloudflare tunnel](0011-self-hosted-edge.md) (superseded by 0014)
- [0012. Harden the router declaratively before it faces the internet](0012-bulletproof-router-hardening.md) (accepted)
- [0013. Choose an edge authentication proxy](0013-edge-auth-proxy.md) (rejected)
- [0014. Manage the Cloudflare tunnel from the repo and expose only three hosts](0014-declarative-minimal-cloudflare-exposure.md) (accepted)
- [0015. Keep the router on NixOS and move toward a zoned network model](0015-zoned-network-on-a-nixos-router.md) (accepted)
- [0016. Adopt a concrete zoned IP scheme](0016-concrete-zoned-ip-scheme.md) (accepted)
- [0017. Establish a defense-in-depth baseline](0017-defense-in-depth-baseline.md) (accepted)

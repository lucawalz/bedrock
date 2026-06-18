---
status: proposed
date: 2026-06-18
---

# 0035. Standalone GitOps-managed cloud cluster

## Context

The home cluster is currently the only GitOps-managed environment. horizon can now provision a standalone Hetzner k3s cluster end to end: a `default` CAPI ClusterClass (a KThreesControlPlane, worker MachineDeployments, and a HetznerCluster with a control-plane load balancer), the `bedrock-cluster-node` image that forms a control plane with its role taken at runtime and networks over the private NIC (see [0034](0034-standalone-cluster-node-snapshot.md)), per-cluster control-plane and worker replica counts, and per-cluster object naming where the control plane is `<cluster>-master` and the workers are `<cluster>-worker`.

What a created cluster does not have today is any in-cluster GitOps. It boots as a bare k3s cluster. To become a true peer of the home environment, a second cluster running in the cloud, it needs its own continuous reconciliation of a Git source.

One constraint shapes the design. The home cluster's manifests assume home-specific hardware and topology: MetalLB layer-2 VIPs, Longhorn on local node disks, the zoned VLAN and IP scheme, the router and DNS split-horizon, and the Tailscale paths. A cloud cluster cannot reconcile those wholesale. Mirroring therefore means reconciling a cluster-appropriate path or overlay, not a byte-for-byte copy of the home cluster.

## Decision

Split the work into two layers.

Layer 1 is already realized and is recorded here for completeness. horizon `cluster create` provisions the standalone cluster substrate through the `default` ClusterClass and the `bedrock-cluster-node` image, with `--cp-replicas` and `--replicas` controlling the control-plane and worker counts, and per-cluster naming drawn from the ClusterClass `naming.template` fields. The cluster lifecycle (machines, scaling, deletion) stays CAPI-managed.

Layer 2 is proposed. A created cluster can opt into mirroring the GitOps environment through a `cluster create --mirror` flag. When set, after the cluster is provisioned horizon bootstraps Flux on the new cluster, pointed at a GitHub repository defined in horizon configuration as a `mirror` source repo and path. The new cluster then runs its own Flux and reconciles that source independently. Each created cluster is a self-managing peer, not a satellite of the home cluster.

The chosen mechanism is to run Flux on the new cluster itself, reconciling a config-defined repo, over the alternatives below. It keeps each cluster self-managing and GitOps-native, isolates failure so the home cluster's Flux is neither a dependency nor a single point of control, and matches the model the home cluster already uses, which keeps one mental model for operating both.

## Options considered

These cover how Flux lands on the new cluster.

- Own Flux on the new cluster, reconciling a config-defined repo, chosen. The cluster runs its own flux-system and reconciles the mirror repo and path. It is self-managing and isolated. The cost is that Flux must be installed and credentialed per cluster, and decryption keys (SOPS and age) must be delivered to the peer.
- Hub Flux, where the home cluster's Flux reconciles the new cluster through its `-kubeconfig` secret via a Kustomization `spec.kubeConfig`, rejected. It is simpler on day one and needs no second Flux, but it couples the peer's health to the home cluster, makes the home Flux a single point of control, and pushes workload-cluster credentials into the home control plane.
- A CAPI ClusterResourceSet, where a labelled ResourceSet installs Flux at provision time and the cluster then self-reconciles, rejected. It is CAPI-native and automatic, but the install is implicit, addon ordering and upgrades are harder to reason about, and it is less explicit than a horizon-driven bootstrap tied to the `--mirror` intent.

## Consequences

horizon config gains a mirror source, a GitHub repo and path, and `cluster create --mirror` wires it. Without the flag a created cluster stays a bare substrate. A bootstrap mechanism is needed to install Flux on the peer and create the GitRepository plus a Kustomization for the cluster path, and a repo deploy key or token must be provisioned for the peer.

Secret material is the open question to settle before Layer 2 lands. Any SOPS or age-encrypted secrets in the source require the decryption key on the peer, and distributing and scoping that key is not yet decided. The repo layout is the other open choice. The mirror source should expose a cluster-appropriate path or overlay of cloud-safe infrastructure rather than the home cluster's hardware-coupled manifests, and whether peers live under a per-cluster path in this repo or in a separate repo is still to decide.

The boundary between the two planes is fixed: cluster lifecycle stays CAPI-managed, while in-cluster apps and infrastructure become GitOps-managed on the peer, and the two planes must not fight over the same objects.

This builds on [0029](0029-single-selectable-capi-node-snapshot.md) for the single selectable node snapshot, [0033](0033-adopt-external-controlplane-object.md) and [0030](0030-externally-managed-control-plane.md) for the externally managed control plane that is the home burst path and contrasts with the topology-managed control plane used here, and [0034](0034-standalone-cluster-node-snapshot.md) for the provider-agnostic ClusterClass and the standalone node image.

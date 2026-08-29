---
status: superseded by 0049
date: 2026-06-18
---

# 0035. Standalone GitOps-managed cloud cluster

> Superseded by [0049](0049-remove-aws-multicloud-build.md), which removes the AWS build and the gitops-peer primitive this record introduced.

## Context

The home cluster is currently the only GitOps-managed environment. horizon can now provision a standalone Hetzner k3s cluster end to end: a `default` CAPI ClusterClass (a KThreesControlPlane, worker MachineDeployments, and a HetznerCluster with a control-plane load balancer), the `bedrock-cluster-node` image that forms a control plane with its role taken at runtime and networks over the private NIC (see [0034](0034-standalone-cluster-node-snapshot.md)), per-cluster control-plane and worker replica counts, and per-cluster object naming where the control plane is `<cluster>-master` and the workers are `<cluster>-worker`.

What a created cluster does not have today is any in-cluster GitOps. It boots as a bare k3s cluster. To become a true peer of the home environment, a second cluster running in the cloud, it needs its own continuous reconciliation of a Git source.

Two constraints shape the design. The first is that the cluster and its GitOps are the durable source of truth. The bedrock repository and the in-cluster CAPI controllers must keep a peer running with no dependency on horizon, which is a convenience tool for on-demand nodes, clusters, and backups and may not be maintained indefinitely. A bootstrap mechanism that runs only when an operator invokes horizon would leave a peer that cannot rebuild itself once horizon is gone.

The second is that the home cluster's manifests assume home-specific hardware and topology: MetalLB layer-2 VIPs, Longhorn on local node disks, the zoned VLAN and IP scheme, the router and DNS split-horizon, and the Tailscale paths. A cloud cluster cannot reconcile those wholesale. Mirroring therefore means reconciling a cluster-appropriate path or overlay, not a byte-for-byte copy of the home cluster.

## Decision

Split the work into two layers.

Layer 1 is already realized and is recorded here for completeness. horizon `cluster create` provisions the standalone cluster substrate through the `default` ClusterClass and the `bedrock-cluster-node` image, with `--cp-replicas` and `--replicas` controlling the control-plane and worker counts, and per-cluster naming drawn from the ClusterClass `naming.template` fields. The cluster lifecycle (machines, scaling, deletion) stays CAPI-managed.

Layer 2 lands the mirroring as a CAPI `ClusterResourceSet`. The ResourceSet matches any cluster labelled `bedrock.io/gitops-peer=true` and installs Flux on it at provision time, pointed at the cloud-safe overlay under `kubernetes/peers/base`. The peer then runs its own Flux and reconciles that overlay independently. Each peer is a self-managing member of the GitOps environment, not a satellite of the home cluster.

The ResourceSet is reconciled by the same CAPI controllers that already own the cluster lifecycle, so a peer self-bootstraps whenever it carries the label, with no operator step and no horizon invocation. The install rides the management cluster's existing reconciliation rather than a one-shot client command, which is what makes a peer reproducible from the repository alone.

## Options considered

These cover how Flux lands on the peer.

- A CAPI `ClusterResourceSet` that installs Flux on any cluster labelled `bedrock.io/gitops-peer=true` and points it at `kubernetes/peers/base`, chosen. It is CAPI-native and reconciled by the management cluster's own controllers, so a peer self-bootstraps from a label with no operator step and no dependency on horizon. The cost is that the install is implicit and addon ordering and upgrades take more care to reason about than an explicit per-cluster apply.
- A horizon-driven bootstrap, where a `cluster create --mirror` flag has horizon install Flux on the peer after provisioning and point it at a repo and path from horizon configuration, rejected. An earlier draft of this record chose this option and rejected the ResourceSet, on the assumption that horizon was the central path through which peers were created. That assumption no longer holds: horizon is a convenience tool that may not be maintained, so a bootstrap that runs only when horizon is invoked leaves a peer that cannot rebuild itself from the repository. The inversion follows directly from making the cluster and its GitOps, not horizon, the durable source of truth.
- Hub Flux, where the home cluster's Flux reconciles the peer through its `-kubeconfig` secret via a Kustomization `spec.kubeConfig`, rejected. It is simpler on day one and needs no second Flux, but it couples the peer's health to the home cluster, makes the home Flux a single point of control, and pushes workload-cluster credentials into the home control plane.

## Consequences

A peer self-bootstraps without horizon. Labelling a cluster `bedrock.io/gitops-peer=true` is enough for the ResourceSet to install Flux and bind it to `kubernetes/peers/base`, so the peer comes up reconciling the shared cloud-safe overlay with no client invocation and no horizon-held configuration. An unlabelled cluster stays a bare substrate.

Secret material remains the open item. Any SOPS or age-encrypted secrets in the overlay require the decryption key on the peer, and distributing and scoping that age key to peers is not yet decided. Until it is, the base overlay holds only material that needs no in-cluster decryption.

Per-cluster overlays beyond the shared base are deferred. Every peer reconciles the same `kubernetes/peers/base` for now; layering per-cluster paths or variants on top of that base is left for when a second peer needs to diverge.

The boundary between the two planes is fixed: cluster lifecycle stays CAPI-managed, while in-cluster apps and infrastructure become GitOps-managed on the peer, and the two planes must not fight over the same objects.

This builds on [0029](0029-single-selectable-capi-node-snapshot.md) for the single selectable node snapshot, [0033](0033-adopt-external-controlplane-object.md) and [0030](0030-externally-managed-control-plane.md) for the externally managed control plane that is the home burst path and contrasts with the topology-managed control plane used here, and [0034](0034-standalone-cluster-node-snapshot.md) for the provider-agnostic ClusterClass and the standalone node image. The first cloud peer authored directly in bedrock rather than through horizon is recorded in [0036](0036-aws-via-managed-eks-control-plane.md).

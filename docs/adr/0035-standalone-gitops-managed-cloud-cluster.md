---
status: superseded by 0049
date: 2026-06-18
---

# 0035. Standalone GitOps-managed cloud cluster

## Context

The home cluster was the only GitOps-managed environment. horizon could already provision a standalone Hetzner k3s cluster end to end through a `default` CAPI ClusterClass and the `bedrock-cluster-node` image from [0034](0034-standalone-cluster-node-snapshot.md), with per-cluster replica counts and per-cluster object naming. What a created cluster did not have was any in-cluster GitOps: it booted as a bare k3s cluster. To become a true peer of the home environment it needed its own continuous reconciliation of a Git source.

Two constraints shaped the design. The cluster and its GitOps are the durable source of truth: the bedrock repository and the in-cluster CAPI controllers must keep a peer running with no dependency on horizon, which is a convenience tool that may not be maintained indefinitely, so a bootstrap that runs only when an operator invokes horizon would leave a peer that cannot rebuild itself. And the home cluster's manifests assume home-specific hardware and topology, from MetalLB layer-2 VIPs and Longhorn on local disks to the zoned VLAN scheme and the split-horizon DNS, so a cloud cluster cannot reconcile them wholesale. Mirroring therefore means reconciling a cluster-appropriate overlay, not a byte-for-byte copy.

## Decision

Layer 1 is the cluster substrate, already realized: horizon provisions a standalone cluster through the `default` ClusterClass and the standalone node image, with flags controlling the control-plane and worker counts and per-cluster naming drawn from the ClusterClass naming templates. The cluster lifecycle stays CAPI-managed.

Layer 2 lands the mirroring as a CAPI `ClusterResourceSet` that matches any cluster carrying the gitops-peer label and installs Flux on it at provision time, pointed at a cloud-safe overlay. The peer then runs its own Flux and reconciles that overlay independently, so each peer is a self-managing member of the GitOps environment rather than a satellite of the home cluster. The ResourceSet is reconciled by the same CAPI controllers that already own the cluster lifecycle, so a peer self-bootstraps whenever it carries the label, with no operator step and no horizon invocation, which is what makes a peer reproducible from the repository alone.

## Options considered

- A CAPI `ClusterResourceSet` that installs Flux on any labelled cluster and points it at the shared peer overlay, chosen. It is CAPI-native and reconciled by the management cluster's own controllers, so a peer self-bootstraps from a label with no dependency on horizon. The cost is that the install is implicit, and addon ordering and upgrades take more care to reason about than an explicit per-cluster apply.
- A horizon-driven bootstrap, where a flag on cluster creation has horizon install Flux on the peer and point it at a repo and path from horizon configuration, rejected. A bootstrap that runs only when horizon is invoked leaves a peer that cannot rebuild itself from the repository, which follows directly from making the cluster and its GitOps, not horizon, the durable source of truth.
- Hub Flux, where the home cluster's Flux reconciles the peer through its kubeconfig secret, rejected. It is simpler on day one and needs no second Flux, but it couples the peer's health to the home cluster, makes the home Flux a single point of control, and pushes workload-cluster credentials into the home control plane.

## Consequences

A peer self-bootstraps without horizon: labelling a cluster is enough for the ResourceSet to install Flux and bind it to the shared cloud-safe overlay, and an unlabelled cluster stays a bare substrate. The boundary between the two planes is fixed, with cluster lifecycle CAPI-managed and in-cluster apps and infrastructure GitOps-managed on the peer, and the two must not fight over the same objects.

Secret material remained the open item, since any encrypted secrets in the overlay require the decryption key on the peer and distributing and scoping that key was not decided, so the base overlay held only material needing no in-cluster decryption. Per-cluster overlays beyond the shared base were deferred until a second peer needed to diverge. [0049](0049-remove-aws-multicloud-build.md) removes the AWS build and the gitops-peer primitive this record introduced, so neither open item was ever settled.

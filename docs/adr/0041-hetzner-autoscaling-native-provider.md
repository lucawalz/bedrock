---
status: accepted
date: 2026-06-19
---

# 0041. Autoscale Hetzner burst nodes with the native cluster-autoscaler provider

## Context

Hetzner Cloud exposes no managed Kubernetes control plane. The home cluster is k3s on three bare-metal nodes, and "Hetzner autoscaling" reduces to one thing: add Hetzner VMs as k3s agents to the existing home cluster when capacity runs out, and delete them when idle.

The implementation from [0024](0024-autoscaler-owned-burst-pool.md), [0025](0025-elastic-and-reserved-node-pools.md), [0030](0030-externally-managed-control-plane.md), and [0033](0033-adopt-external-controlplane-object.md) modelled that as a full Cluster API workload cluster named `burst`, whose control plane is the home cluster reached through a custom ExternalControlPlane object, provisioned by CAPH and managed by Rancher Turtles, scaled by the cluster-autoscaler in `clusterapi` mode. Wrapping three home nodes in a synthetic Cluster to satisfy CAPI produced a standing set of failures: the autoscaler crash-loops because it resolves the infra template at the CAPI v1beta2 contract while CAPH v1.1.6 serves only v1beta1 and no v1beta2 line of CAPH is released; Rancher imports the synthetic cluster a second time alongside `local`; and abrupt node teardown strands Longhorn node records, which is the reason the reaper in [0026](0026-orphan-node-reaper.md) exists. The whole machinery is overhead for a requirement that needs none of it.

## Decision

Autoscale Hetzner burst capacity with the cluster-autoscaler's native `hetzner` cloud provider, and retire the Cluster API stack for Hetzner.

The autoscaler runs as one in-cluster Deployment with `cloudProvider: hetzner`. It reads a SOPS-encrypted `HCLOUD_TOKEN`, declares node groups through `--nodes=min:max:servertype:region:pool` flags, and takes per-pool image, cloud-init, labels, and taints from `HCLOUD_CLUSTER_CONFIG`. The image is the existing baked snapshot from [0027](0027-durable-capi-node-snapshot-pipeline.md), selected by label so the weekly rebuild pipeline carries over unchanged. The cloud-init runs the k3s agent join against the home control plane, replacing the config file CAPH used to write, so `modules/k3s/pool-node.nix` takes its server, token, and labels from instance metadata instead of a CAPI-written file. The provider deletes the server and the Node object together on scale-down, so no orphan Node record survives and the reaper no longer has to chase one. The hcloud cloud-controller-manager stays out, since burst nodes join over Tailscale, store on Longhorn, and never front a Hetzner load balancer.

Automatic capacity (the `elastic` group) is owned by the autoscaler and scales from zero on pending-pod pressure. On-demand capacity (the `reserved` group) is owned by the horizon tool, which creates and deletes Hetzner servers through the hcloud API directly against the same snapshot, under a label the autoscaler does not manage. The two never contend, and the cluster autoscales with no horizon involvement, which keeps horizon optional.

This supersedes 0024, 0025, 0026, 0030, and 0033, and removes the Hetzner side of [0037](0037-flux-operator-controlplane-install.md). The Cluster API claim in [0036](0036-aws-via-managed-eks-control-plane.md) narrows to AWS, where a managed control plane makes it fit.

## Options considered

- The native `hetzner` provider, chosen. It implements the actual requirement as one Deployment, one secret, and one image pipeline, scales from zero, deletes server and Node atomically, and reuses the existing snapshot. It deletes the synthetic Cluster, CAPH, Turtles, and the ExternalControlPlane object along with the contract skew and the double-import.
- Keep the Cluster API model and pin the autoscaler to the v1beta1 contract with capacity annotations. This restores autoscaling today but retains every piece of wrapper complexity and depends on a deprecated API version served only until a future core bump drops it. A stopgap, not a design.
- Karpenter for Hetzner. No mature provider exists in 2026; the only routes are the cluster-api provider, which returns to the broken contract, or a hand-port. Karpenter's instance-shape bin-packing is also wasted on a burst pool of one or two fixed shapes.

## Consequences

The crash-looping autoscaler, the Rancher double-import, and the dependency on an unreleased CAPH all disappear, replaced by one autoscaler Deployment and one SOPS secret.

The orphan-node reaper from [0026](0026-orphan-node-reaper.md) is kept rather than removed, but narrowed to its Longhorn-finalize pass. The provider's clean scale-down deletes the server and the Node object together, so the reaper no longer needs to chase orphan Node records. An uncleanly terminated burst node still strands a `nodes.longhorn.io` record that the native provider does not clean up, which is the case [0040](0040-reap-orphaned-longhorn-nodes.md) added the finalize pass for, so that pass stays. The node-pool shape moves from MachineDeployment manifests to autoscaler flags in the HelmRelease, which is simpler rather than weaker. The home cluster autoscales itself with no operator action, and on-demand bursts go through horizon talking to hcloud directly. The change must be verified with a scale-from-zero test: a pod that only an elastic burst node can host triggers a server create, the node joins and the pod schedules, and removing the pod returns the group to zero and deletes the server. The cost is a refactor of the node image join path and the loss of the single-API-for-every-cloud framing, which AWS retains on its own merits under [0042](0042-ephemeral-eks-autoscaling-and-s3-foothold.md).

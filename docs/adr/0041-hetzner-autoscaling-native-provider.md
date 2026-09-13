---
status: superseded by 0062
date: 2026-06-19
---

# 0041. Autoscale Hetzner burst nodes with the native cluster-autoscaler provider

## Context

Hetzner Cloud exposes no managed Kubernetes control plane. The home cluster is k3s on three bare-metal nodes, and Hetzner autoscaling reduces to one thing: add Hetzner VMs as k3s agents to the existing home cluster when capacity runs out, and delete them when idle. The implementation from [0024](0024-autoscaler-owned-burst-pool.md), [0025](0025-elastic-and-reserved-node-pools.md), [0030](0030-externally-managed-control-plane.md), and [0033](0033-adopt-external-controlplane-object.md) modelled that as a full Cluster API workload cluster named `burst`, whose control plane was the home cluster reached through a custom control-plane object, provisioned by CAPH, managed by Rancher Turtles, and scaled by the cluster-autoscaler in its Cluster API mode. Wrapping three home nodes in a synthetic Cluster to satisfy CAPI produced a standing set of failures: the autoscaler crash-looped because it resolved the infra template at a contract version CAPH does not serve and no release of CAPH does, Rancher imported the synthetic cluster a second time, and abrupt node teardown stranded Longhorn node records, which is why the reaper in [0026](0026-orphan-node-reaper.md) exists. The whole machinery is overhead for a requirement that needs none of it.

## Decision

Autoscale Hetzner burst capacity with the cluster-autoscaler's native Hetzner cloud provider, and retire the Cluster API stack for Hetzner. The autoscaler is one in-cluster Deployment reading a SOPS-encrypted API token, with node groups declared as flags and their per-pool image, cloud-init, labels, and taints in one config environment variable.

Nodes boot from the baked snapshot of [0027](0027-durable-capi-node-snapshot-pipeline.md), selected by label so the rebuild pipeline carries over unchanged. Their cloud-init runs the k3s agent join in place of the config file CAPH used to write, so the node module reads its server, token, and labels from instance metadata. The provider deletes the server and the Node object together on scale-down. The cloud-controller-manager stays out, since burst nodes join over Tailscale, store on Longhorn, and never front a Hetzner load balancer.

Automatic capacity stays with the autoscaler and scales from zero on pending-pod pressure. On-demand capacity is owned by horizon, which creates and deletes servers through the provider API under a label the autoscaler does not manage, so the two never contend and the cluster autoscales with no horizon involvement. This supersedes [0024](0024-autoscaler-owned-burst-pool.md), [0025](0025-elastic-and-reserved-node-pools.md), [0026](0026-orphan-node-reaper.md), [0030](0030-externally-managed-control-plane.md), and [0033](0033-adopt-external-controlplane-object.md), and narrows the Cluster API claim in [0036](0036-aws-via-managed-eks-control-plane.md) to AWS, where a managed control plane makes it fit.

## Options considered

- The native Hetzner provider, chosen. It implements the actual requirement without a synthetic Cluster, so CAPH, Turtles, and the control-plane object go with it, taking the contract skew and the double import along.
- Keep the Cluster API model and pin the autoscaler to the older contract with capacity annotations. This restores autoscaling but retains every piece of wrapper complexity and depends on a deprecated API version served only until a future core bump drops it. A stopgap, not a design.
- Karpenter for Hetzner. No mature provider exists; the only routes are the Cluster API provider, which returns to the broken contract, or a hand-port, and Karpenter's instance-shape bin-packing is wasted on a burst pool of one or two fixed shapes.

## Consequences

The crash-looping autoscaler, the Rancher double import, and the dependency on an unreleased CAPH all disappear, replaced by one Deployment and one SOPS secret. That secret carries the per-pool config injected as environment variables, and the helm-controller does not restart the Deployment when the secret's content changes, so the Deployment carries the Reloader annotation from [0020](0020-reloader-config-driven-rollouts.md) through a post-renderer patch, since the chart exposes no Deployment-level annotation field. The reaper from [0026](0026-orphan-node-reaper.md) is kept rather than removed but narrowed to its Longhorn pass, because an uncleanly terminated burst node still strands a record the native provider does not clean up, which is the case [0040](0040-reap-orphaned-longhorn-nodes.md) added that pass for. Removing the old stack has its own ordering constraint: the `burst` Cluster must be deleted before its control-plane CRD, since deleting the CRD first leaves the Cluster's finalizer unable to resolve and wedges the deletion. The change is verified with a scale-from-zero test, where a pod only a burst node can host triggers a server create and removing it returns the group to zero. The cost is a refactor of the node image join path and the loss of the single-API-for-every-cloud framing, which AWS retains on its own merits under [0042](0042-ephemeral-eks-autoscaling-and-s3-foothold.md).

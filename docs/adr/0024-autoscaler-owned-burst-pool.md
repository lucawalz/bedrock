---
status: superseded by 0041
date: 2026-06-15
---

# 0024. Let the cluster-autoscaler own the burst pool replica count

## Context

The `burst-workers` MachineDeployment in `caph-system` provisions cloud worker nodes through Cluster API when the home cluster runs out of room. Bedrock committed `spec.replicas: 0` on that MachineDeployment, and the cluster-capi Flux kustomization reconciled the field on every pass. The in-cluster cluster-autoscaler from [0023](0023-tailscale-overlay.md)'s Cluster API direction is meant to grow and shrink the pool in response to pending-pod pressure, and horizon scales it directly during a burst. A live test on 2026-06-15 confirmed the conflict: any scale-up was reverted to zero within minutes by Flux server-side apply, and the freshly provisioned burst node was deprovisioned before it could carry work. Two controllers were fighting for the same field, and the GitOps reconcile always won.

## Decision

The cluster-autoscaler owns `spec.replicas` on the `burst-workers` MachineDeployment; Flux no longer manages it. The field is removed from the committed manifest entirely, so Flux server-side apply neither sets nor reverts it. The autoscaler discovers the pool through the existing `autoDiscovery.labels` match on `cluster.x-k8s.io/cluster-name: burst` and reads its scaling bounds from two annotations placed on the MachineDeployment: `cluster.x-k8s.io/cluster-api-autoscaler-node-group-min-size: "0"` and `cluster.x-k8s.io/cluster-api-autoscaler-node-group-max-size: "2"`. A minimum of zero lets the pool drain to no nodes when idle, and a maximum of two caps burst cost. With the min-size annotation present, the MachineDeployment defaulting webhook leaves an absent replicas field alone rather than defaulting it, so the manifest can omit it cleanly.

## Options considered

- Remove `spec.replicas` and let the autoscaler own it, chosen. The two controllers stop contending, live and autoscaler-driven scale persists, and pending-pod pressure drives capacity as intended.
- Keep `spec.replicas: 0` in git and have Flux ignore the field with a managed-fields or kustomize patch exclusion. This keeps a value committed that does not reflect reality and adds reconcile machinery to suppress its own field, which is harder to reason about than simply not owning it.
- Pin replicas in git and drop the autoscaler. This abandons burst autoscaling and forces every scale event through a commit, which is too slow for pending-pod pressure.

## Consequences

Flux no longer pins the burst pool size; the autoscaler and horizon are the scale authorities, and a scale-up survives reconciliation. The committed manifest no longer records a desired replica count, so the live count must be read from the cluster rather than from git, which is the accepted trade for letting scale react in real time. The bounds remain in git as the min and max annotations, so cost and floor stay reviewable and version controlled. The autoscaler scale-down settings from its HelmRelease govern how quickly an idle pool returns to zero.

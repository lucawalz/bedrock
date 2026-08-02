---
status: accepted
date: 2026-08-02
---

# 0071. Deploy the horizon operator from its published OCI chart

## Context

[0062](0062-retire-elastic-cluster-autoscaler.md) left on-demand capacity entirely to the horizon tool, run from a workstation against the hcloud API. That covers provisioning, but nothing in the cluster reacts when a burst node fails to arrive or leaves without being cleaned up. Horizon now ships an operator that runs in the cluster: it reconciles leases against hcloud and collects orphaned Node objects once a node has missed its registration window.

Horizon publishes that operator as a Helm chart to `ghcr.io`. The chart is the artifact an adopter installs, and it is the only supported way to install the operator.

Two things in this repository decide how a chart can be consumed. Every chart source lives in `kubernetes/clusters/home/sources/helm/` as a `HelmRepository`, and there is not a single `OCIRepository` in the estate. `scripts/render-helm-releases.sh`, which CI runs directly and again through `scripts/apply-policies.sh`, resolves a release's source by matching `spec.chart.spec.sourceRef.name` against the `HelmRepository` documents in that directory. A release that points at a chart through `spec.chartRef` has no `spec.chart.spec` for the renderer to read, so it renders nothing, reports no source, and fails the build.

The reaper from [0026](0026-orphan-node-reaper.md) is the other thing the operator touches. Its first pass selects nodes labelled `horizon.dev/pool=reserved` whose Ready condition is not True and deletes them, every ten minutes. Its second pass, added by [0040](0040-reap-orphaned-longhorn-nodes.md) and retained by [0062](0062-retire-elastic-cluster-autoscaler.md), finalizes stranded `nodes.longhorn.io` records. The first pass and the operator now claim the same job, and they disagree about timing. Horizon allows a node fifteen minutes to register. A reserved node carries `horizon.dev/pool=reserved` from cloud-init before k3s has joined, so for the first fifteen minutes of its life it matches the reaper's selector exactly: labelled reserved, Ready not True, and entirely healthy. On a ten-minute schedule the reaper deletes it mid-join.

## Decision

Deploy the horizon operator into the cluster from its published chart, and narrow the reaper to the pass the operator does not own.

The chart is consumed as a `HelmRepository` of `type: oci` pointing at `ghcr.io`, referenced from the `HelmRelease` through `spec.chart.spec.sourceRef` like every other chart in the estate. This is the same mechanism the Flux operator chart already uses through `kubernetes/clusters/home/sources/helm/controlplane.yaml`, so OCI delivery is not new here, only the second instance of it. It keeps the release renderable by CI, which is the difference between a chart change being caught in a pull request and being caught by the cluster.

The custom resource definitions install from the chart and are never deleted. The release sets `install.crds: Create` and `upgrade.crds: CreateReplace`, matching cert-manager, MetalLB, and Traefik. Deleting them is not a recoverable operation: the lease CRD is the only record of which hcloud servers the operator owns, so removing it cascade-deletes every lease and leaves the servers running and billing with nothing left in the cluster that knows about them. The CRDs therefore outlive the release. Uninstalling the operator is a Helm uninstall, never a CRD removal, and a teardown that needs the servers gone releases the leases first.

The cluster installs the chart an adopter would install, at a pinned version, from the registry it is published to. Nothing is vendored, forked, or rendered to plain manifests. If a chart release breaks its defaults, its RBAC, or its CRD upgrade path, this cluster is where it breaks, on the next reconcile, rather than in someone else's install months later.

The reaper loses its Node-deletion pass. The `node-reaper` CronJob is renamed `longhorn-node-finalizer` and keeps only the Longhorn pass, because that is now all it does. The operator owns Node deletion and is the only thing that should: it knows when a node was created and how long its registration window has left, which the reaper never did. Its cluster-scoped grant narrows from get, list, and delete on core `nodes` to get alone, which is what the surviving pass needs for its backing-node existence check. The namespaced Role on `longhorn.io` nodes is unchanged.

## Options considered

- A `HelmRepository` of `type: oci`, chosen. It is one manifest, it matches every other source in the repository, and CI renders and policy-checks the resulting workloads without any change to the tooling.
- An `OCIRepository` with `spec.chartRef` on the release. This is the more current Flux idiom and it is what would allow pinning by digest and verifying a cosign signature, neither of which the estate does for any chart today. The cost is not the manifest, it is everything around it: `render-helm-releases.sh` would need a second source kind and a second resolution path, and because `apply-policies.sh` renders through it, an unrendered release silently drops out of policy coverage rather than failing loudly. Introducing the estate's only `OCIRepository` for its newest and least-proven chart is the wrong place to take that on. It is worth doing when digest pinning is adopted across the board, as one change to the renderer and every source at once.
- Vendor the rendered manifests into this repository. It removes the registry as a runtime dependency and makes upgrades an explicit diff. Rejected because it defeats the reason for deploying here at all: a vendored copy exercises this repository's rendering, not the published chart, so the install path an adopter follows could break and nothing here would notice.
- Keep the reaper's Node-deletion pass as a safety net under the operator. Rejected. Two controllers deleting nodes on different clocks is not redundancy, and the reaper holds the shorter one. It would delete healthy nodes during a normal join, and the failure would look like an unreliable provider rather than a scheduled job.

## Consequences

Orphaned Node objects are collected by something that knows why they are orphaned, and a node joining slowly is left alone until its window closes. The fifteen-minute window is now the only deadline that applies to a reserved node, instead of whichever of two timers fired first.

This repository is a live test of the horizon chart. A bad release reaches the cluster on the next reconcile, which is the point, and the price is that a chart bug is an outage here before it is a bug report. The version is pinned, so the exposure is bounded to upgrades rather than to every publish.

The CRDs are now a resource with a lifecycle nobody automates. Flux will not remove them, which is what protects the leases, and that also means a genuine removal has to be done by hand and in the right order. Rebuilding the cluster carries the same ordering constraint: discarding cluster state before the leases are released leaves servers running and billing in the hcloud project with nothing left to reconcile them.

The renamed CronJob is a delete and a create rather than an in-place edit, since the Flux Kustomization that owns `kubernetes/infrastructure/configs/reaper` has `prune: true`. The old `node-reaper` CronJob, its ServiceAccount, and its cluster-scoped grant are removed on the first reconcile after the change lands. `pod-reaper`, which shares the directory and has nothing to do with any of this, is untouched.

The estate still has no `OCIRepository` and no digest-pinned chart. That is a deliberate deferral, not an oversight, and it stays a gap until the renderer learns the second source kind.

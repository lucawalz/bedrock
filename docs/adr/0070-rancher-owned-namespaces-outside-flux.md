---
status: accepted
date: 2026-07-29
---

# 0070. Leave the Rancher-owned namespaces outside Flux

## Context

The cluster reconciles from Git, and `kubernetes/clusters/home/namespaces/` is meant to be the list of namespaces that exist. The live cluster has eleven namespaces beginning `cattle-`. Exactly one, `cattle-system`, carries a `kustomize.toolkit.fluxcd.io/name` label. Rancher created the other ten and Flux knows nothing about them.

Nothing recorded whether that boundary was deliberate, so every audit of the estate has had to work it out again. It looks like a hole in GitOps coverage, and the obvious remedy of declaring the namespaces in Git is wrong in a way that only becomes clear once it has been tried.

Rancher is more than a workload here. It installs and reconciles its own components as system charts, including Rancher Turtles, which owns the cluster-api core provider. `cattle-capi-system` carries a `meta.helm.sh/release-name` of `rancher-turtles`, so Rancher already owns that namespace through a Helm release of its own. Rancher 2.14 reinstalls Turtles if it is removed, so an operator who deletes it is overruled on the next reconcile.

## Decision

Treat the Rancher-created namespaces as owned by Rancher, and declare only `cattle-system` in Git.

Rancher is the right lifecycle owner for anything it installs as a system chart. Declaring `cattle-turtles-system`, `cattle-capi-system`, the three `cattle-fleet-*` namespaces or the remaining Rancher data and token namespaces in Flux would give two controllers a claim on the same objects. Flux would apply and prune from Git while Rancher recreated from its own charts. That is a loop, not a drift that settles, and it would show up as continuous reconcile churn instead of a clean failure.

`cattle-system` is the exception. It holds the Rancher release itself, which this repository does install through Flux, so its namespace is declared alongside every other namespace the repository owns.

Tie the Kyverno exemptions to this decision explicitly. All the Rancher namespaces appear in `config.resourceFiltersIncludeNamespaces` and `config.webhooks.namespaceSelector` in the Kyverno HelmRelease, so their workloads are never evaluated at admission. That exemption exists because the estate cannot fix manifests it does not author. It is part of this boundary, not an unrelated allowance.

## Options considered

- Leave the namespaces to Rancher and record the boundary, chosen. It matches where control actually sits, costs nothing to implement, and turns a recurring audit finding into a decision that can be read once.
- Declare the namespaces in Flux. Rejected. It gives two owners to objects Rancher recreates from its own charts, and pruning from Git would fight the product instead of correcting drift.
- Remove Rancher, Turtles and cluster-api entirely so the namespaces never exist. Rejected previously and separately. Rancher earns its place as the cluster's management interface, and Turtles arrives with it whether or not the cluster-api features are used.

## Consequences

The boundary is explicit, and the absence of these namespaces from Git is now a decision.

The cost is that their contents upgrade through Rancher, not through a commit. Drift inside them is invisible to Flux and to any review of the repository, and anything installed there has to be inspected in the cluster to be known. The nineteen dead cluster-api custom resource definitions removed in July 2026 show what that means in practice: they carried `clusterctl.cluster.x-k8s.io` labels, no Flux labels, and no reference anywhere under `kubernetes/`, so deleting a file would have achieved nothing. The removal had to be imperative and left no trace in Git.

Policy coverage is weaker here too. These workloads are exempt from Kyverno by configuration, so they pass policy without being evaluated. Bringing them under Pod Security Admission later would have to account for that, since a namespace label carries no equivalent exemption and takes effect immediately.

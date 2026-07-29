---
status: accepted
date: 2026-07-29
---

# 0070. Leave the Rancher-owned namespaces outside Flux

## Context

The cluster reconciles from Git, and `kubernetes/clusters/home/namespaces/` is meant to be the list of namespaces that exist. Comparing that list against the live cluster shows eleven namespaces beginning `cattle-`, of which exactly one, `cattle-system`, carries a `kustomize.toolkit.fluxcd.io/name` label. The other ten were created by Rancher itself and are unknown to Flux.

Nothing recorded whether that is a deliberate boundary or an omission, so every audit of the estate has had to re-derive the answer. It reads as a gap in GitOps coverage, and the obvious remedy of declaring the namespaces in Git is wrong in a way that is not obvious until it has been tried.

Rancher is not merely a workload here. It installs and reconciles its own components as system charts, including Rancher Turtles, which in turn owns the cluster-api core provider. `cattle-capi-system` carries a `meta.helm.sh/release-name` of `rancher-turtles`, so that namespace is already owned by a Helm release Rancher manages. Rancher 2.14 reinstalls Turtles if it is removed, which means an operator who deletes it is overruled by the product on the next reconcile.

## Decision

Treat the Rancher-created namespaces as owned by Rancher, and declare only `cattle-system` in Git.

Rancher is the correct lifecycle owner for anything it installs as a system chart. Declaring `cattle-turtles-system`, `cattle-capi-system`, the three `cattle-fleet-*` namespaces, or the remaining Rancher data and token namespaces in Flux would create two controllers with a claim on the same objects: Flux would apply and prune from Git while Rancher recreated from its own charts. The resulting conflict is not a one-off drift that settles, it is a loop, and it would surface as continuous reconcile churn rather than as a clean failure.

`cattle-system` is the deliberate exception. It holds the Rancher release itself, which this repository does install through Flux, so its namespace is declared alongside every other namespace the repository owns.

Couple the Kyverno exemptions to this decision explicitly. All the Rancher namespaces appear in `config.resourceFiltersIncludeNamespaces` and `config.webhooks.namespaceSelector` in the Kyverno HelmRelease, so their workloads are never evaluated at admission. That exemption exists because the estate cannot fix manifests it does not author, and it is part of the same boundary rather than an unrelated allowance.

## Options considered

- Leave the namespaces to Rancher and record the boundary, chosen. It matches where control actually sits, costs nothing to implement, and converts a recurring audit finding into a decision that can be read once.
- Declare the namespaces in Flux. Rejected. It creates two owners for objects Rancher recreates from its own charts, and pruning from Git would fight the product rather than correct drift.
- Remove Rancher, Turtles and cluster-api entirely, so the namespaces never exist. Rejected separately and previously; Rancher earns its place as the cluster's management interface, and Turtles arrives with it whether or not the cluster-api features are used.

## Consequences

The boundary is now explicit, and the absence of these namespaces from Git is a decision rather than an apparent gap.

The cost is that their contents upgrade through Rancher rather than through a commit, so drift inside them is invisible to Flux and to any review of the repository. Anything installed there has to be inspected in the cluster to be known. The clearest illustration is the nineteen dead cluster-api custom resource definitions removed in July 2026: they carried `clusterctl.cluster.x-k8s.io` labels, no Flux labels, and no reference anywhere under `kubernetes/`, so deleting a file would have achieved nothing and the removal had to be imperative and left no trace in Git.

Policy coverage is correspondingly weaker in these namespaces. Their workloads are exempt from Kyverno by configuration, which means they pass policy because they are not evaluated rather than because they comply. Any future attempt to bring them under Pod Security Admission has to account for that, because a namespace label carries no equivalent exemption and would be enforced immediately.

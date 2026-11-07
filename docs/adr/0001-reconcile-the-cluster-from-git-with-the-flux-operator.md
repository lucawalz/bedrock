---
status: accepted
date: 2026-11-07
---

# 0001. Reconcile the cluster from git with the Flux Operator

## Context

The cluster is meant to be rebuildable from this repository alone. The rebuild in November 2026 was its first cold bootstrap, and a cold start exposes ordering faults that a long-running cluster hides: custom resources applied before their CRDs, Helm installs that fail once and then strand, and a Git source that cannot resolve its host before cluster DNS exists.

## Decision

- Flux v2 runs under the Flux Operator. The `FluxInstance` in `kubernetes/clusters/home/flux-operator/instance` pins the Flux minor line, lists the controllers, and syncs `kubernetes/clusters/home` from `main`. The `StrictPostBuildSubstitutions` feature gate is on, so a missing substitution variable fails the build instead of rendering an empty string.
- `just bootstrap` seeds a fresh cluster. It applies CoreDNS first, because k3s runs with `--disable=coredns` and Flux cannot fetch git without DNS, then installs the operator chart, applies the `FluxInstance`, and creates the SOPS age key Secret and the sync deploy key. From then on the repository is the only way state reaches the cluster.
- The Flux Kustomizations in `kubernetes/clusters/home/config/` are grouped into files for reading only. `dependsOn` alone decides order: each Kustomization depends on the sources, secrets and namespaces it consumes and on the Kustomization that installs the CRDs its objects need. CRD-only charts reconcile in `cluster-crds` ahead of their consumers. `scripts/check-crd-order.sh` and `scripts/check-crd-charts.sh` guard this in CI.
- Every HelmRelease uses the `RetryOnFailure` strategy for both install and upgrade. A rollback remediation has no target when the first install fails, which stranded releases on the cold start; retrying the same revision converges once the cause clears. `scripts/check-helmrelease-remediation.sh` fails CI on any HelmRelease without it.
- Kustomizations that hold Jobs whose spec changes set `force: true`, since a Job pod template is immutable.
- Flux error events go to ntfy through notification-controller Alerts.

## Consequences

- A cold bootstrap converges without manual steps beyond `just bootstrap` and the owner-held keys.
- A failed upgrade is not rolled back. It keeps retrying until the fix lands in git, which is the intended way to recover.
- The age key and the deploy key are the inputs a rebuild needs that the repository cannot hold.

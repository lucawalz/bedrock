---
status: accepted
date: 2026-06-18
---

# 0037. Move the home Flux install to the ControlPlane flux-operator

## Context

The home cluster has run Flux v2.8.8 since the start, installed with `flux bootstrap`. That command writes a static `gotk-components.yaml` and `gotk-sync.yaml` into `kubernetes/clusters/home/flux-system` and commits them, and Flux then reconciles itself from those generated files. It works, but the install is a frozen artifact: bumping a controller or changing the sync is a regenerate-and-commit step rather than a declarative spec, and the generated manifests are the kind of by-hand output the rest of this repository exists to avoid.

The governing principle across the recent records is that the cluster and its GitOps are the durable source of truth. A static generated install sits awkwardly under that principle, and it also blocks something concrete: the official Flux Operator Web UI, the maintained dashboard from the project that now stewards Flux, is driven by a `FluxInstance` object that a bootstrap install does not produce. The home cluster has no Flux dashboard at all today. An earlier trial of Capacitor was abandoned because it is unmaintained, and Headlamp was weighed as a non-disruptive read-only alternative, but it would leave the install itself frozen and add a second tool rather than modernise the one already in use.

## Decision

Install the ControlPlane flux-operator declaratively and let it own the Flux install.

A new OCI-type `HelmRepository` named `controlplane` points at `oci://ghcr.io/controlplaneio-fluxcd/charts`. A Flux `HelmRelease` in `flux-system` installs the `flux-operator` chart, version 0.52.0, from it. The operator is then driven by a `FluxInstance` (apiVersion `fluxcd.controlplane.io/v1`) named `flux` in `flux-system`, which declares the whole install: all six controllers, the 2.8.x distribution from `ghcr.io/fluxcd`, the cluster settings, and the same SSH Git sync the bootstrap used (`ssh://git@github.com/lucawalz/bedrock`, ref `refs/heads/main`, path `kubernetes/clusters/home`, pull secret `flux-system`).

The adoption is in-place, not parallel. `spec.sync.name` on a FluxInstance defaults to the instance's own namespace, so the operator reconciles a `GitRepository` and root `Kustomization` both named `flux-system`. Those are exactly the objects the bootstrap created, so the operator takes them over where they stand rather than standing up a second source and root alongside them. The install becomes a spec without a flag day on the sync.

The operator's built-in Web UI (service `flux-operator`, port 9080, AGPL-3.0, free) is exposed at `flux.syslabs.dev` through a Traefik `IngressRoute` behind a basic-auth middleware, with a `NetworkPolicy` that permits ingress to port 9080 only from the Traefik namespace. The basic-auth credential is a SOPS-encrypted secret. This is the dashboard the cluster lacked, and it replaces the rejected Capacitor trial.

## Options considered

- The ControlPlane flux-operator with a FluxInstance, chosen. It makes the install a declarative spec, adopts the existing bootstrap objects in place through the `sync.name` default, and brings the maintained official Web UI. The cost is the takeover itself, which has to be sequenced carefully so the operator does not fight the bootstrap files it is adopting.
- Headlamp as a read-only dashboard over the existing bootstrap install, rejected. It would add a Flux view with no disruption, but it leaves the install frozen and adds a separate tool rather than modernising the one in use. It treats the symptom, not the static install underneath.
- Capacitor, rejected. It was trialled earlier as a Flux dashboard but is unmaintained, so it is not a basis for the home install going forward.
- Staying on `flux bootstrap`, rejected. It keeps a working but frozen install that cannot produce a FluxInstance, so the official Web UI stays out of reach and controller and sync changes stay regenerate-and-commit steps.

## Consequences

The install becomes fully declarative, which is more GitOps-conformant than the bootstrap it replaces, not less: controllers, distribution, and sync all live in a reviewed FluxInstance instead of a generated artifact.

The takeover is staged as two pushes, and the ordering is load-bearing. The operator stamps prune-disable and ssa-ignore annotations on the controllers it adopts and a prune-disable annotation on the namespace, but the root Kustomization it generates is itself `prune: true` with no self-exemption. So the bootstrap `gotk-components.yaml` and `gotk-sync.yaml` cannot be deleted in the same push that installs the operator, or the reconciling root would prune the very source and root it runs from. The first push lands the operator, the HelmRepository, the FluxInstance, and the Web UI, and the operator's adoption is then verified live. Only after that, and only after the live `flux-system` `GitRepository` and `Kustomization` are annotated `kustomize.toolkit.fluxcd.io/prune: disabled` out-of-band, are the two bootstrap files removed in a second push. The annotation breaks the self-prune cascade; the recovery backstop if a step goes wrong is SSH access to the nodes.

The separate gitops-peer bootstrap under `infrastructure/cluster-api/gitops-peer/files/` still ships its own `gotk-components.yaml` and `gotk-sync.yaml` to seed Flux on a peer through a ClusterResourceSet (see [0035](0035-standalone-gitops-managed-cloud-cluster.md)). That path is unchanged here and remains a candidate for the same operator treatment later.

This refines [0002](0002-nixos-flakes-flux-gitops.md), which chose Flux v2 and noted it manages itself after a one-time bootstrap; the operator is what self-management now looks like, with the bootstrap reduced to the initial seed and the install carried declaratively from there.

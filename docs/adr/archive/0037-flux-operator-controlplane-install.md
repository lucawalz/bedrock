---
status: accepted
date: 2026-06-18
---

# 0037. Move the home Flux install to the ControlPlane flux-operator

## Context

The home cluster had run Flux since the start, installed with `flux bootstrap`. That command writes a static component and sync manifest pair into the cluster path and commits them, and Flux then reconciles itself from those generated files. It works, but the install is a frozen artifact: bumping a controller or changing the sync is a regenerate-and-commit step rather than a declarative spec, and the generated manifests are the kind of by-hand output the rest of this repository exists to avoid. That also blocks something concrete. The official Flux Operator Web UI, the maintained dashboard from the project that now stewards Flux, is driven by a `FluxInstance` object that a bootstrap install does not produce, and the cluster had no Flux dashboard at all. An earlier trial of Capacitor was abandoned because it is unmaintained, and Headlamp was weighed as a non-disruptive read-only alternative but would leave the install itself frozen and add a second tool.

## Decision

Install the ControlPlane flux-operator declaratively and let it own the Flux install. An OCI `HelmRepository` points at the ControlPlane chart registry, a `HelmRelease` in `flux-system` installs the operator, and the operator is driven by a `FluxInstance` named `flux` under `kubernetes/clusters/home/flux-operator/instance/`, which declares the whole install: all six controllers, the distribution, the cluster settings, and the same SSH Git sync the bootstrap used. The adoption is in-place rather than parallel: the sync name defaults to the instance's own namespace, so the operator reconciles a `GitRepository` and root `Kustomization` both named `flux-system`, which are exactly the objects the bootstrap created, and it takes them over where they stand instead of standing up a second source and root alongside them. The operator's built-in Web UI is exposed at `flux.syslabs.dev` through a Traefik IngressRoute, with a NetworkPolicy admitting its port only from the Traefik namespace. It first ran behind a basic-auth middleware and moved behind the Authentik forward-auth middleware with the rest of the internal dashboards in [0038](0038-authentik-sso-for-internal-dashboards.md).

## Options considered

- The ControlPlane flux-operator with a FluxInstance, chosen. It makes the install a declarative spec, adopts the existing bootstrap objects in place through the sync-name default, and brings the maintained official Web UI. The cost is the takeover itself, which has to be sequenced carefully so the operator does not fight the bootstrap files it is adopting.
- Headlamp as a read-only dashboard over the existing bootstrap install, rejected. It would add a Flux view with no disruption, but it leaves the install frozen and adds a separate tool rather than modernising the one in use. It treats the symptom, not the static install underneath.
- Capacitor, rejected. It was trialled earlier as a Flux dashboard but is unmaintained, so it is not a basis for the home install going forward.
- Staying on `flux bootstrap`, rejected. It keeps a working but frozen install that cannot produce a FluxInstance, so the official Web UI stays out of reach and controller and sync changes stay regenerate-and-commit steps.

## Consequences

The install is fully declarative and more GitOps-conformant than the bootstrap it replaces, with controllers, distribution, and sync all in a reviewed FluxInstance instead of a generated artifact. The ordering of the takeover was load-bearing and is the lesson worth keeping: the operator stamps prune-disable and ssa-ignore annotations on the controllers it adopts, but the root Kustomization it generates is itself pruning with no self-exemption, so the bootstrap files could not be deleted in the same push that installed the operator without the reconciling root pruning the very source and root it runs from. The operator landed first, its adoption was verified live, the live source and root were annotated prune-disabled out of band to break the self-prune cascade, and only then were the bootstrap files removed. This refines [0002](0002-nixos-flakes-flux-gitops.md), which chose Flux v2 and noted it manages itself after a one-time bootstrap; the operator is what self-management now looks like, with the bootstrap reduced to the initial seed and the install carried declaratively from there.

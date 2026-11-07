---
status: superseded by 0063
date: 2026-07-06
---

# 0061. Lay out the repository as a multi-region fleet

## Context

The repository was organised around a single cluster: everything the home cluster ran lived under one cluster-cohesive subtree that fully described it. For one cluster this is the simplest possible layout and it had served well. The direction of the project was no longer one cluster. The home datacentre was meant to grow into a fleet, with the three physical nodes staying the hub and first region and cloud regions joining as spokes, and the Cluster API peer list already anticipated this with regions declared but not provisioned. What was missing was a repository shape that lets a new region be added without copying an entire cluster subtree and hand-editing it, because that pattern guarantees the copies drift apart the moment they are touched.

A region differs from another region in a small, bounded set of facts: its name, its zone, its domain, and which infrastructure archetype it runs. An on-prem edge like home runs Traefik, MetalLB, and Longhorn against bare metal, where a cloud edge runs a cloud controller manager, a cloud CSI driver, and a cloud load balancer instead. Everything else is region-neutral. The layout had no place to express that a region is mostly a set of shared blueprints plus a few regional scalars, so every region would have had to restate the whole of itself. That mirrors a split the cluster already makes one layer up, where Cluster API describes a fleet as a reusable ClusterClass plus a small Cluster object carrying variables.

## Decision

Restructure the repository from the single cluster-cohesive tree into a multi-region fleet layout, separating blueprint, instance, and management plane. A region becomes a stampable abstraction defined by nothing more than its per-region values file and a thin cluster entrypoint.

Apps become shared blueprints laid out as a region-neutral base plus one overlay per edge profile, because a regional app varies structurally by edge rather than by region name: the blog serves through a Traefik IngressRoute on the on-prem edge and a plain Ingress on a cloud edge. A home-only app that never spans regions stays flat. Infrastructure splits into a shared base and two region archetypes, an on-prem edge profile and a cloud edge profile, so a region selects a profile rather than restating an infrastructure tree, and the per-concern Kustomization split from [0058](0058-split-cluster-infrastructure-kustomizations.md) is preserved inside the profiles. A region-invariant fragment shared across app overlays would be factored into a Kustomize Component; none is needed yet, so the mechanism is reserved for the first one that appears. The management plane separates from the workload clusters into its own tree holding the ClusterClass, the providers, and Rancher, which makes the arrangement hub-and-spoke: the hub owns the fleet definition and the spokes are the workload clusters it stamps.

Per-region values live in one directory per region as a ConfigMap carrying the regional scalars, and thin Flux entrypoints bind those values to the shared blueprints for that spoke to reconcile under its own Flux. The Cluster API `Cluster` that provisions a spoke is declared by the hub, since provisioning is a hub concern. A region therefore exists as its values directory, its spoke entrypoint, and its hub-side Cluster instance, and adding one changes nothing else in the tree.

Stamping is hybrid, matching each mechanism to what it carries best. Kustomize Components carry structure, the shape that is the same for every region, and Flux `postBuild.substituteFrom` injects the per-region scalars from the region ConfigMap, extending the values ConfigMap the repository already keeps. Three guard rails keep the substitution honest: `StrictPostBuildSubstitutions` makes a missing variable fail the reconcile loudly instead of rendering an empty string, variables carry defaults where a sensible one exists, and manifests whose braces are Helm templates rather than Flux variables are annotated out of substitution.

Home stays the hub and the Flux sync root, because the three physical nodes cannot be split across regions. The cloud regions are declared as blueprints and values but not provisioned, so the fleet architecture is demonstrated at zero running cost: the shape is real and reviewable, and nothing is billed until a region is switched on. Two regional apps exercise the range the layout has to absorb. The blog is stateless and goes active-active for free, proving the easy end. The chat service, with inference and user state, sits at the hard end and forces the questions a stateless app never raises: how state is held across regions, and whether inference runs regionally or centrally.

## Options considered

- The fleet base-and-overlays layout with region archetypes and a thin per-cluster entrypoint, chosen. It matches the documented Flux guidance on repository structure, its region archetypes are a well-trodden way to describe a class of cluster once and stamp many, and it reaches the goal that adding a region touches only a values file and a thin entrypoint while composing cleanly with the ClusterClass split it mirrors.
- Cluster-cohesive self-contained trees, one full subtree duplicated per region, rejected. It is the current shape extended by copy-paste, which is exactly the pattern that guarantees drift: a fix has to be applied by hand to every copy, the copies diverge the first time one is edited in isolation, and the divergence is invisible until a region behaves differently for a reason nobody recorded.
- One hand-written overlay per region rather than a parameterised archetype, rejected. It removes the full-subtree duplication but replaces it with per-region boilerplate that grows with every region, where an archetype plus a values file makes a new region a data change against an existing blueprint.

## Consequences

Adding a region becomes a bounded, low-risk change: a values file and a thin entrypoint that selects an archetype, with no infrastructure tree to copy and no app manifests to restate. The blueprint is written and reviewed once, and every region inherits fixes to it without a per-region edit.

The layout is more indirect than the single cluster-cohesive tree. A reader tracing what a region runs follows the entrypoint to a profile, into the base, and through the components and substituted variables, rather than reading one self-contained subtree top to bottom. This is the same trade [0058](0058-split-cluster-infrastructure-kustomizations.md) made at the infrastructure layer, taken one level up, and the payoff scales with the number of regions. The strict substitution guard rails also move a class of error from silent to loud, which means every variable a blueprint references has to be present or carry a default, and Helm-values manifests have to be annotated out of substitution. That discipline is the cost of making the stamping trustworthy.

The declared-but-not-provisioned regions carry a standing obligation to stay real, because nothing exercises them and they can rot unnoticed until a region is switched on. Keeping them buildable in review is what keeps the zero-cost demonstration honest.

The layout is built to be retired as cleanly as it is added. Home is never parameterized, so decommissioning the fleet touches nothing it runs: deleting the region values, the spoke entrypoints, the cloud edge profile, the hub-side spoke Cluster instances, and each app's cloud overlay, then collapsing the on-prem profile back into the infrastructure tree, returns the repository to a single-cluster shape with the home region byte-for-byte unchanged. [0063](0063-return-to-single-region.md) carried that teardown out once the demonstration was delivered, which is why the teardown is recorded beside the build: a demonstration architecture that cannot be retired cleanly is not a complete one.

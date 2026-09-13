---
status: accepted, implemented
date: 2026-07-06
---

# 0063. Return the homelab to a single region after the fleet demonstration

## Context

The multi-region fleet layout in [0061](0061-multi-region-fleet-layout.md) was built to demonstrate proper multi-region production GitOps for a university presentation and a blog post, not for operational use. The homelab is three bare-metal nodes run by one operator, running a second region is uneconomical, and there is no requirement for one. The layout is byte-identical for the home cluster and every cloud region is declared but unprovisioned, so it costs nothing to run. Once the presentation and the post are delivered, though, it is standing structure with no consumer: an edge profile with a single archetype in use, region values that vary against nothing, and spoke entrypoints no cluster reconciles. Carried indefinitely on a single-operator homelab, that reads as generality without a purpose. The work done along the way that improved the homelab is independent of the layout and worth keeping; the cross-region machinery is not.

## Decision

Once the demonstration is delivered, return the repository to a single home cluster and collapse the fleet layout to a single-cluster shape. Remove the isolated multi-region additions: the region values, the spoke entrypoints, the cloud edge profile, the hub-side spoke Cluster instances, and each app's cloud overlay. Then collapse the on-prem edge profile back into the infrastructure tree, so a single cluster is no longer described through an archetype it is the only member of. Because the home cluster was never parameterized, the reversion deletes structure it does not reconcile and touches no running workload, so the home region renders byte-for-byte as before. This supersedes [0061](0061-multi-region-fleet-layout.md) once carried out.

## Options considered

- Revert to a single cluster once the demonstration is done, chosen. The fleet layout served its purpose as a reference architecture and a talk. Kept past that it is overhead for an estate that runs one cluster by hand, and the honest form of a single-cluster repository is a single-cluster repository.
- Keep the fleet layout indefinitely. Rejected. With the demonstration delivered there is no second region and no plan for one, so the profiles, region values, and spoke entrypoints become single-use scaffolding that implies a generality the estate does not have.
- Keep the layout but strip only the cloud spokes. Rejected. It removes the running-cost risk but leaves the profile split and the region values in place around a single member, which is the least coherent of the three states: neither a clean single cluster nor a populated fleet.

## Consequences

The homelab returns to the simplest layout that serves one operator, and the multi-region design is not lost, because [0061](0061-multi-region-fleet-layout.md) stays in the record as superseded rather than deleted. The reversion is a delete of the isolated multi-region directories plus one collapse of the edge profile, verified by the same rendered-output gate that guarded the build, so the change is provably confined to structure no cluster runs.

Carried out on 6 July 2026. The multi-region directories and the entire Cluster API stack went, including the Rancher-Turtles providers, the ClusterClass, and the spoke bootstrap. The two Hetzner spokes were deprovisioned first, so their servers, load balancers, and networks were deleted by their controller before it was uninstalled. Rancher is kept, now as the operational plane rather than a fleet provisioner: it owns cluster visibility, access control, and the application catalogue, while Flux remains the sole reconciler of in-cluster state, and the two planes must not both own the same objects.

The platform was not flattened into a single list. It collapsed into a controllers and configs split, the canonical Flux shape, so operator installs reconcile before the custom resources that depend on them. The per-concern Kustomizations from [0058](0058-split-cluster-infrastructure-kustomizations.md) were preserved and every Flux Kustomization kept its name, with only its path changing, which for identical rendered output is a no-op where a rename would prune and recreate every managed object. Nothing is preserved outside the working tree: the tag that once held the spoke tunnel secrets was removed, because a fleet the estate no longer runs is a remnant rather than an asset, and the demonstrated architecture stays recoverable from git history.

Two things this record kept have since gone, and neither loss touches its decision. The backups and disaster recovery it preserved were removed with the Hetzner account by [0081](0081-retire-the-hetzner-account.md), so what persists unchanged is the hardening alone, and on-demand capacity through horizon went with the same account. The return to a single region, the collapse of the profile split, and the removal of the Cluster API substrate all stand as written.

---
status: accepted but not yet implemented
date: 2026-07-06
---

# 0063. Return the homelab to a single region after the fleet demonstration

## Context

The multi-region fleet layout in [0061](0061-multi-region-fleet-layout.md) was built to demonstrate proper multi-region production GitOps for a university presentation and a blog post, not for operational use. The homelab is three bare-metal nodes run by one operator, running a second region is uneconomical, and there is no requirement for one. The fleet layout is byte-identical for the home cluster and every cloud region is declared but unprovisioned, so it costs nothing to run. Once the presentation and the post are delivered, though, it is standing structure with no consumer: an edge profile with a single archetype in use, region values that vary against nothing, and spoke entrypoints no cluster reconciles. Carried indefinitely on a single-operator homelab, that reads as generality without a purpose.

The work done along the way that genuinely improved the homelab is independent of the fleet layout and is worth keeping: the CloudNativePG Barman disaster recovery and Velero backups, the architecture-decision-record consolidation, the retirement of the elastic autoscaler in [0062](0062-retire-elastic-cluster-autoscaler.md), and the general hardening. The cross-region machinery is not.

## Decision

Once the demonstration is delivered, return the repository to a single home cluster and collapse the fleet layout to a single-cluster shape.

Remove the isolated multi-region additions: `regions/`, the spoke entrypoints under `clusters/`, `infrastructure/profiles/edge-cloud`, the hub-side spoke `Cluster` instances under `fleet/cluster-api/peers`, and each app's cloud overlay. Then collapse `infrastructure/profiles/edge-onprem` back into `infrastructure/`, so a single cluster is no longer described through an archetype it is the only member of. Keep the backups and disaster recovery, and keep on-demand capacity beyond the three bare-metal nodes provided by horizon alone, as decided in [0062](0062-retire-elastic-cluster-autoscaler.md).

Because the home cluster was never parameterized, the reversion deletes structure the home cluster does not reconcile and touches no running workload. The home region renders byte-for-byte as before. This supersedes [0061](0061-multi-region-fleet-layout.md) once carried out.

## Options considered

- Revert to a single cluster once the demonstration is done, chosen. The fleet layout served its purpose as a reference architecture and a talk. Kept past that it is overhead for an estate that runs one cluster by hand, and the honest form of a single-cluster repository is a single-cluster repository.
- Keep the fleet layout indefinitely. Rejected. With the demonstration delivered there is no second region and no plan for one, so the profiles, region values, and spoke entrypoints become single-use scaffolding that implies a generality the estate does not have. Nothing operational is gained, and a later reader is left to wonder what the structure is for.
- Keep the layout but strip only the cloud spokes. Rejected. It removes the running-cost risk but leaves the profile split and the region values in place around a single member, which is the least coherent of the three states: neither a clean single cluster nor a populated fleet.

## Consequences

The homelab returns to the simplest layout that serves one operator, and the multi-region design is not lost. [0061](0061-multi-region-fleet-layout.md) stays in the record as superseded rather than deleted, so the reasoning, the trade-offs, and the demonstration remain legible to anyone who reads the log. The backups, disaster recovery, and hardening persist unchanged.

The reversion is a delete of the isolated multi-region directories plus one collapse of the edge profile, verified by the same rendered-output gate that guarded the build: the home cluster's manifests are identical before and after, so the change is provably confined to structure no cluster runs. The teardown steps were recorded in [0061](0061-multi-region-fleet-layout.md) when the fleet was built, so this record only sets the decision to carry them out.

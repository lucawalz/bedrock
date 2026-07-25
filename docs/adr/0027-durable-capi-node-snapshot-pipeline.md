---
status: accepted
date: 2026-06-15
---

# 0027. Guarantee a usable CAPI node snapshot at all times

## Context

CAPH provisions every burst node from a single Hetzner snapshot named `bedrock-pool-node`, built by the `build-pool-node-snapshot` workflow with Packer and nixos-anywhere. The workflow rebuilt only when a node-image input changed (`flake.nix`, `flake.lock`, `modules/k3s/pool-node.nix`, `modules/k3s/hetzner-scaffolding.nix`, `infra/packer/**`), keyed on a tree hash carried as the `bedrock-nixos-hash` label, and a cleanup job deleted every managed snapshot whose hash did not match the current one.

Two properties of that design could leave zero usable images, and with no image CAPH cannot provision any node. The pipeline only ran on input changes, so a static config produced no fresh build for arbitrarily long while the lone snapshot aged, and any out-of-band loss had nothing to recreate it. The prune kept only the current-hash snapshot with no count floor, so a single mistaken evaluation could remove the last image, and it ran on `needs.build.result == 'success'` even when the build job succeeded by skipping (snapshot already present) without confirming the named snapshot actually existed in Hetzner. The 2026-06-15 provisioning outage traced to this class of failure.

## Decision

The pipeline guarantees a usable snapshot through three additions, keeping the existing on-input-change push trigger and `workflow_dispatch`.

A weekly `schedule` rebuild runs every Monday at 04:00 UTC. On a scheduled run the existence check is forced to miss so a fresh image is built even when inputs are unchanged, refreshing the snapshot before it can age out.

A verification step runs before any prune and queries Hetzner for a snapshot carrying the current `bedrock-nixos-hash`. If none is found the step exits non-zero and the prune never runs, so cleanup can only proceed once the image the cluster depends on is confirmed present.

The prune retains a floor of three generations and never considers the current-hash snapshot for deletion. Stale snapshots are sorted newest first; the current-hash images are always preserved, the two newest stale generations are kept as fallback, and only older stale snapshots are removed. The floor is a single `SNAPSHOT_RETENTION` workflow variable.

## Options considered

- Scheduled rebuild plus a verified, retention-floored prune, chosen. It removes both the aging-out path and the prune-to-zero path with no new infrastructure, and the floor keeps rollback images.
- Keep the input-change-only trigger and rely on operators to dispatch a rebuild. This leaves the aging-out gap open to human memory, which is what failed.
- Drop the prune entirely and let snapshots accumulate. This trades the zero-image risk for unbounded storage cost and an ever-growing image list, and still leaves no periodic freshness guarantee.

## Consequences

A usable `bedrock-pool-node` snapshot is present at all times: a fresh one is built weekly regardless of input churn, the prune cannot run until the current snapshot is verified to exist, and it can never reduce the set below the retention floor or touch the image the cluster currently depends on. The weekly rebuild adds one Packer build and a short-lived Hetzner server per week even when nothing changed, which is the accepted cost of the freshness guarantee. The retention floor keeps at least two prior generations for rollback at the cost of holding a few extra snapshots. The prune assumes Hetzner honours `sort=created:desc`; if it does not, the floor still holds and the current image is still preserved, only the choice of which stale generations survive becomes non-deterministic.

## Update 2026-07-25

The record above describes an estate that no longer exists, and the forced rebuild it decided on had been failing on every scheduled run since it was introduced.

Cluster API and its Hetzner provider were retired in [0062](0062-retire-elastic-cluster-autoscaler.md) and [0063](0063-return-to-single-region.md). The `bedrock-pool-node` image, the `build-pool-node-snapshot` workflow, and `modules/k3s/pool-node.nix` are gone with them. The surviving pipeline is `build-cluster-node-snapshot`, which builds the standalone `bedrock-cluster-node` image introduced in [0034](0034-standalone-cluster-node-snapshot.md), and its consumer is the horizon tool from [0062](0062-retire-elastic-cluster-autoscaler.md). Horizon still selects the boot image by the `caph-image-name` label, so the promotion step is kept and only its provider-specific description is corrected; the label key stays because it is horizon's configured default and renaming it would need a coordinated change in that tool. The title and file name of this record keep their original wording so the decision log stays stable, and CAPI should be read as the provisioning path of the time rather than the one in use.

The forced miss is removed. Packer derives `snapshot_name` from the same tree hash that the existence check queries, so forcing the check to report a miss on a scheduled run made Packer attempt a snapshot whose name already existed, and it exited non-zero before creating a server. Every scheduled run from 22 June 2026 onward failed this way in under a minute. Because the build job failed, the verification gate in the cleanup job was skipped, so promotion and pruning never ran either. The freshness guarantee was therefore not merely expensive, it produced nothing and disabled the safeguards it was meant to protect.

Freshness now comes from input churn rather than from a forced rebuild. Renovate bumps `flake.lock` on its normal cadence, which changes the tree hash and triggers a build through the existing push trigger, so the image tracks nixpkgs without a scheduled rebuild. The weekly schedule is kept and is a no-op for the build when inputs are unchanged, which is what lets it still exercise verification, promotion, and pruning, and lets it rebuild for real when an out-of-band loss leaves no snapshot for the current hash. That covers both failure paths the original decision was written against, without the collision.

Two smaller corrections come with it. The cron is set to `0 4 * * 1`, matching the Monday 04:00 UTC this record already specified; it had drifted to 05:00. A `pull_request` trigger scoped to the Packer templates and the workflow runs `packer init`, `packer fmt -check`, and `packer validate`, so a template change is checked before it reaches `main` rather than on the push that would build from it. The tree-hash computation moved into `scripts/nixos-image-hash.sh` and is used by both jobs, since it was duplicated between them and a divergence would silently build one image and verify another.

The decision itself, that the pipeline guarantees a usable snapshot through scheduled attention, a verification gate before any prune, and a retention floor, is unchanged. This record is amended rather than superseded.

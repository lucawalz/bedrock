---
status: accepted, CAPI estate superseded by 0062 and 0063
date: 2026-06-15
---

# 0027. Guarantee a usable CAPI node snapshot at all times

## Context

Every burst node was provisioned from a single Hetzner snapshot built with Packer and nixos-anywhere. The workflow rebuilt only when a node-image input changed, keyed on a tree hash carried as a snapshot label, and a cleanup job deleted every managed snapshot whose hash did not match the current one. Two properties of that design could leave zero usable images, and with no image nothing could provision a node. The pipeline only ran on input changes, so a static config produced no fresh build for arbitrarily long while the lone snapshot aged, and any out-of-band loss had nothing to recreate it. The prune kept only the current-hash snapshot with no count floor, so a single mistaken evaluation could remove the last image, and it ran even when the build job had succeeded by skipping, without confirming the named snapshot actually existed. A provisioning outage traced to this class of failure.

## Decision

The pipeline guarantees a usable snapshot through periodic attention, a verification gate before any prune, and a retention floor, keeping the existing on-input-change push trigger and manual dispatch. A weekly rebuild originally ran every Monday at 04:00 UTC; [0081](0081-retire-the-hetzner-account.md) removed that schedule when the Hetzner account closed, leaving the workflow triggered only by a change to its own inputs or by hand, and freshness now rides input churn, since Renovate bumps `flake.lock` on its normal cadence and that changes the tree hash. A verification step runs before any prune and queries for a snapshot carrying the current hash; if none is found it exits non-zero and the prune never runs, so cleanup can only proceed once the image is confirmed present. The prune retains a floor of three generations, never considers the current-hash snapshot for deletion, and takes its floor from a single workflow variable.

## Options considered

- Periodic rebuild plus a verified, retention-floored prune, chosen. It removes both the aging-out path and the prune-to-zero path with no new infrastructure, and the floor keeps rollback images.
- Keep the input-change-only trigger and rely on operators to dispatch a rebuild. This leaves the aging-out gap open to human memory, which is what failed.
- Drop the prune entirely and let snapshots accumulate. This trades the zero-image risk for unbounded storage cost and an ever-growing image list, and still leaves no periodic freshness guarantee.

## Consequences

The prune cannot run until the current snapshot is verified to exist, and it can never reduce the set below the retention floor or touch the image in use, at the cost of holding a few extra snapshots for rollback. The forced-rebuild half of the original decision was itself a fault and was withdrawn: Packer derives the snapshot name from the same tree hash the existence check queries, so forcing the check to report a miss made Packer attempt a snapshot whose name already existed, and it exited non-zero before creating a server. Every scheduled run from 22 June 2026 onward failed that way in under a minute, and because the build job failed the verification gate was skipped, so promotion and pruning never ran either. Removing the forced miss restored both safeguards, and the tree-hash computation moved into `scripts/nixos-image-hash.sh` so the build and cleanup jobs cannot diverge and silently build one image while verifying another. The CAPI estate this record was written against is gone with [0062](0062-retire-elastic-cluster-autoscaler.md) and [0063](0063-return-to-single-region.md); the surviving pipeline builds the standalone `bedrock-cluster-node` image from [0034](0034-standalone-cluster-node-snapshot.md), its consumer was horizon, and it now sits dormant alongside the rest of the provider-shaped machinery [0081](0081-retire-the-hetzner-account.md) left in place. The title and file name keep their original wording so the decision log stays stable, and CAPI should be read as the provisioning path of the time.

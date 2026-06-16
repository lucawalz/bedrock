---
status: accepted
date: 2026-06-16
---

# 0029. Promote a single CAPH-selectable node snapshot

## Context

CAPH provisions burst and reserved nodes from a Hetzner snapshot referenced by the worker `HCloudMachineTemplate` as `imageName: bedrock-capi-node`. CAPH resolves that value either as an image name or as the value of a `caph-image-name` label, and the snapshots are named per build as `bedrock-capi-node-<hash>`, so the reference resolves through the label rather than the name. The Packer build baked a static `caph-image-name=bedrock-capi-node` label onto every snapshot.

[0027](0027-durable-capi-node-snapshot-pipeline.md) kept a retention floor of three generations and added a weekly rebuild that forces a build even when the node-image inputs are unchanged. Both interact badly with a static selection label. The floor leaves two or three generations carrying the same `caph-image-name`, and the forced weekly build mints a second snapshot with the same name and the same `bedrock-nixos-hash` as the existing one, which the prune never removed because it preserved every current-hash image. With more than one snapshot carrying the selection label, CAPH returns `ImageAmbiguous` and the node stays in `Provisioning` forever. The 2026-06-16 provisioning failure traced to this.

## Decision

Exactly one snapshot carries the selection label at any time, and the workflow sets it rather than Packer.

Packer no longer bakes `caph-image-name`; a freshly built snapshot starts without it and is not selectable until it is promoted. After the existing verify step confirms the current-hash snapshot exists, a promote step adds `caph-image-name=bedrock-capi-node` to the newest current-hash snapshot and removes it from every other snapshot, so a build that has not been verified can never be selected.

The prune additionally deletes older snapshots that share the current hash, keeping only the newest, alongside the existing retention floor for older generations. So a forced weekly rebuild of unchanged inputs replaces its predecessor instead of accumulating a duplicate. The prune still runs only after verification and never removes the newest current-hash snapshot, so the zero-image guarantee from [0027](0027-durable-capi-node-snapshot-pipeline.md) holds.

The `HCloudMachineTemplate` keeps its stable `imageName`, so a rebuild is adopted by the next provision without rewriting the GitOps manifest.

## Options considered

- Promote the selection label onto a single verified snapshot and prune same-hash duplicates, chosen. It keeps the manifest stable and the rollback floor, and confines the change to Hetzner label state managed by CI.
- Pin the unique snapshot name or image ID into the `HCloudMachineTemplate` on each build. It removes the ambiguity, but `HCloudMachineTemplate.spec.template` is immutable, so each rebuild would create a new template and repoint the MachineDeployment, rolling every node in the pool, including on the weekly refresh.
- Bake the label in Packer and keep only one generation. It drops the rollback floor from [0027](0027-durable-capi-node-snapshot-pipeline.md) and reintroduces the prune-to-zero path that record closed.

## Consequences

One snapshot is CAPH-selectable at any time, set only after the image is verified, so an unverified or failed build is never selectable and a routine rebuild never rolls a running node. Older same-hash duplicates are removed after verification rather than before, so the weekly rebuild stops accumulating images while the zero-image guarantee holds. The promote step adds the label to the new snapshot before stripping it from the prior one, so a window of a few seconds can leave both labeled; a provision in that window retries and resolves once the strip completes, and a mid-run CI failure degrades to the prior ambiguous state rather than to no selectable image. The build needs no extra permissions, since it already holds the Hetzner token used for the existing prune.

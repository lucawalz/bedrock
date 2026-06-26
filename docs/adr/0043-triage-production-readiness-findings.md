---
status: accepted
date: 2026-06-20
---

# 0043. Triage production-readiness findings into fixed, accepted, and deferred

## Context

The cluster runs real workloads but had never been measured against a production hardening bar. A sweep with kube-score, kube-linter, and trivy returned findings in the hundreds, and the two code repositories carried their own static-analysis debt: horizon had a dead helper and no lint gate, and bedrock had deadnix and statix lints and no formatter. A raw finding count is not a worklist. Some findings are real gaps, some are deliberate trade-offs that a single-operator home cluster should keep, and some are tool false positives that "fixing" would only obscure. The velero-ui ClusterRole is the clearest example: trivy reports its wildcard as a CRITICAL, but the wildcard is scoped to the `velero.io` API group, with read-write verbs so the dashboard can trigger backups and restores, which is exactly what a backup dashboard needs. Remediating it would weaken nothing and add noise. The work needed a recorded posture, not a sprint to drive a number to zero.

## Decision

Sort the findings into three buckets and act on each differently: fix the genuine gaps, write down the accepted trade-offs so they read as choices rather than oversights, and track the deferred work with an owner and a reason. A scanner's CRITICAL is a hypothesis to verify against the actual manifest and threat model, not a verdict.

Fixed this pass. Both repositories now enforce quality in CI rather than relying on local discipline: horizon gained a golangci-lint gate (gofumpt, govet, staticcheck, errcheck, ineffassign, unused) on top of build, vet, and test, and bedrock gained a blocking gate for nixfmt formatting, statix, and deadnix alongside the existing flake evaluation and kubeconform manifest validation. The dead code was removed, the lints cleared, and the Nix tree formatted. The kubeconform job was corrected to validate the Cluster API provider CRDs against the versions this repo pins rather than a lagging community catalog, so a valid `accessConfig` field on `AWSManagedControlPlane` no longer fails the build. On the workloads, litellm was given resource requests and limits, which closes the last unbounded user pod and matters because an unbounded container sharing the node root disk is the failure mode behind the Longhorn DiskPressure history that [0040](0040-reap-orphaned-longhorn-nodes.md) and the image-GC tuning already address from other angles. homepage and litellm were set to a read-only root filesystem with only the writable mounts each image genuinely needs, the blog probes were split so readiness fails fast while liveness tolerates a blip, and the README was corrected to describe the native Hetzner autoscaler from [0041](0041-hetzner-autoscaling-native-provider.md) instead of the retired Cluster API path.

Accepted trade-offs, documented and left in place. The velero-ui role stays as scoped. Single-replica apps and absent PodDisruptionBudgets are kept, because three home nodes have no high-availability target to protect. Vendor controllers without resource limits, the privileged Longhorn storage DaemonSets, and the system DaemonSets that run as root are all inherent to what those components do. Image digests are not pinned, because tags are pinned and Renovate bumps them, and a digest in the values once wedged the app-template schema. The identical liveness and readiness probes on several workloads come from upstream charts this repo does not template.

Deferred but owned. Ten namespaces, mostly infrastructure, still have no NetworkPolicy; closing that gap means allow-listing real cross-namespace traffic per namespace rather than dropping a blind default-deny, so it is its own careful pass. horizon's thin test coverage in the CLI and CAPI packages and its two high-complexity TUI functions are worth raising but are not load-bearing. The tempo chart has a major upgrade waiting (1.24 to 3.0) that carries a configuration change and belongs behind a maintenance window, and Longhorn has a minor upgrade (1.10 to 1.12) that, given past Longhorn incidents, is taken deliberately rather than on autopilot. The cloudflared image still rides a mutable tag pinned by digest.

## Options considered

- Triage into fixed, accepted, and deferred, chosen. It closes the real gaps, makes the CI gates trustworthy, and turns the remaining findings into an explicit record of what is cut by choice and what is owed.
- Remediate every reported finding. Rejected. Many findings do not apply to a single-operator homelab, some are false positives, and blind remediation is its own risk: a reflexive default-deny NetworkPolicy across every namespace would sever working traffic, and weakening the velero-ui role would buy nothing.
- Suppress the scanners and declare the cluster done. Rejected. The unbounded litellm pod, the writable root filesystems, and the local-only lint discipline were genuine gaps, and an explicit posture is itself the deliverable.

## Consequences

CI now gates formatting, linting, vetting, and tests on both repositories and validates manifests against the CRD schemas the cluster actually deploys, so the gates catch regressions rather than decorate the badge. The accepted trade-offs are written down, so a later reviewer, or the author after six months, sees which corners are deliberate. The deferred work is recorded here with a reason for the delay instead of being lost, and version currency stays with Renovate on bedrock and Dependabot on horizon, both of which hold major bumps for human review, which is why the tempo and Longhorn upgrades wait for a chosen window rather than merging on their own. The cost is that this ADR has to be revisited when a deferred item is taken up or an accepted trade-off stops being acceptable, which is the point of recording them.

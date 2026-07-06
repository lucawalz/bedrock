---
status: accepted
date: 2026-06-20
---

# 0043. Accepted production-readiness trade-offs

## Context

The cluster runs real workloads and was measured against a production hardening bar with kube-score, kube-linter, and trivy. The sweep returned findings in the hundreds, but a raw count is not a worklist. Some findings are real gaps that were closed, some are deliberate trade-offs that a single-operator home cluster should keep, and some are tool false positives that remediating would only obscure. A scanner's CRITICAL is a hypothesis to verify against the actual manifest and threat model, not a verdict. The velero-ui ClusterRole is the clearest example: trivy reports its wildcard as a CRITICAL, but the wildcard is scoped to the `velero.io` API group with read-write verbs so the dashboard can trigger backups and restores, which is exactly what a backup dashboard needs. This record fixes the accepted trade-offs in writing so they read as choices rather than oversights.

## Decision

The following trade-offs are accepted and left in place, each a deliberate choice rather than an unclosed gap:

- The velero-ui ClusterRole keeps its wildcard, scoped to the `velero.io` group with read-write verbs. Narrowing it would weaken nothing and only add noise.
- Single-replica apps and absent PodDisruptionBudgets are kept, because three home nodes have no high-availability target to protect.
- Vendor controllers without resource limits, the privileged Longhorn storage DaemonSets, and the system DaemonSets that run as root are inherent to what those components do.
- Image digests are not pinned, because tags are pinned and Renovate bumps them, and a digest in the values once wedged the app-template schema.
- Identical liveness and readiness probes on several workloads come from upstream charts this repository does not template.

## Options considered

- Record the accepted trade-offs as an explicit posture, chosen. It turns the surviving findings into a statement of what is cut by choice, so a later reviewer sees which corners are deliberate.
- Remediate every reported finding. Rejected. Many findings do not apply to a single-operator homelab, some are false positives, and blind remediation is its own risk: a reflexive default-deny NetworkPolicy across every namespace would sever working traffic, and weakening the velero-ui role would buy nothing.
- Suppress the scanners and declare the cluster done. Rejected. An explicit posture is itself the deliverable, and silencing the scanners would also hide the next real gap.

## Consequences

The accepted trade-offs are written down, so a later reviewer, or the author after six months, sees which corners are deliberate rather than forgotten. The cost is that this record has to be revisited when a trade-off stops being acceptable, which is the point of recording it.

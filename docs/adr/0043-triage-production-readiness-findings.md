---
status: accepted in part, HA and default-deny trade-offs superseded by 0053 and 0066
date: 2026-06-20
---

# 0043. Accepted production-readiness trade-offs

## Context

The cluster runs real workloads and was measured against a production hardening bar with kube-score, kube-linter, and trivy. The sweep returned findings in the hundreds, but a raw count is not a worklist. Some findings are real gaps that were closed, some are deliberate trade-offs that a single-operator home cluster should keep, and some are tool false positives that remediating would only obscure. A scanner's CRITICAL is a hypothesis to verify against the actual manifest and threat model, not a verdict. The Longhorn storage DaemonSets are the clearest example: a scanner reports their privileged containers as a critical finding, and a storage engine that attaches block devices on every node cannot do its job without them. This record fixes the accepted trade-offs in writing so they read as choices.

## Decision

The following trade-offs are accepted and left in place, each a deliberate choice:

- Rancher's system charts and Longhorn's own system-managed components (its instance managers, and longhorn-ui, whose chart exposes no resources key) run without resource limits, as do the file-copy init containers of MetalLB's frr-k8s DaemonSet, which its chart likewise cannot bound; the privileged Longhorn storage DaemonSets and the system DaemonSets that run as root are inherent to what those components do.
- Most container images pin only a tag, which Renovate bumps, because a digest in the values once wedged the app-template schema; a few images pin a tag plus a digest.
- Identical liveness and readiness probes on several workloads come from upstream charts this repository does not template.
- Single-replica apps are kept where the workload has no high-availability target worth protecting. [0053](0053-ha-critical-path-survives-node-loss.md) later moved the critical path off that position after a single node loss took down ingress and authentication, so the surviving single replicas are the ones outside that path.

## Options considered

- Record the accepted trade-offs as an explicit posture, chosen. It turns the surviving findings into a statement of what is cut by choice, so a later reviewer sees which corners are deliberate.
- Remediate every reported finding, rejected. Many findings do not apply to a single-operator homelab, some are false positives, and blind remediation is its own risk. A reflexive default-deny NetworkPolicy across every namespace would have severed working traffic at the time, and narrowing a role that is already scoped to one API group buys nothing.
- Suppress the scanners and declare the cluster done, rejected. An explicit posture is itself the deliverable, and silencing the scanners would also hide the next real gap.

## Consequences

The accepted trade-offs are written down, so a later reviewer sees which corners are deliberate. The cost is that this record has to be revisited when a trade-off stops being acceptable, which is the point of recording it. Default-deny is the clearest case: it stopped being a blanket sweep and became a shared per-app component in [0066](0066-standardize-app-delivery-per-app-kustomizations.md), which is the reasoned version of what the rejected remediation would have done reflexively.

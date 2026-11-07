---
status: accepted
date: 2026-11-07
---

# 0009. Enforce workload policy with Kyverno

## Context

Charts from upstream ship with uneven security contexts and resource settings. A review in git catches what a reviewer notices; admission control catches the rest, including what a chart renders differently after an upgrade.

## Decision

- Five validation policies in `kubernetes/infrastructure/configs/policies` run in `Enforce` mode: CPU and memory requests and a memory limit on every container, `runAsNonRoot`, no privilege escalation, all capabilities dropped, and no `latest` tag. A sixth, mutating policy defaults `allowPrivilegeEscalation` to false.
- The webhooks skip the namespaces of the platform components that cannot meet the policies or that must keep working while Kyverno is down: kube-system, flux-system, longhorn-system, cert-manager, metallb-system, monitoring and cnpg-system.
- Each remaining violation is a named `PolicyException` in `exceptions.yaml`, scoped to one policy, namespace and workload. The current ones cover the Paperless image, which starts as root and switches to its mapped user itself, and the Open WebUI, ntfy and Reloader containers.
- Policy Reporter collects results so background scans surface drift in resources that were admitted before a policy changed.
- `docs/admission-break-glass.md` is the runbook for a webhook that blocks the writes needed to repair it.

## Consequences

- A workload that violates policy fails at admission with the rule named in the error, so new apps set `runAsNonRoot`, a user ID and resources from the start. The scaffold does this by default ([0013](0013-keep-each-app-self-contained-and-scaffold-new-ones.md)).
- The skipped namespaces carry no admission guarantee, which is the price of keeping storage, DNS, certificates and GitOps out of Kyverno's blast radius.
- Excluding a resource later leaves stale failures in existing policy reports until the reports are deleted and rebuilt.

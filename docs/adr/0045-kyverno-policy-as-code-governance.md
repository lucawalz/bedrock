---
status: accepted
date: 2026-06-20
---

# 0045. Govern workloads with Kyverno policy-as-code in audit-first rollout

## Context

The triage in [0043](0043-triage-production-readiness-findings.md) hardened the first-party workloads by hand and wrote down which trade-offs were deliberate. That posture lived only as prose and as the discipline of whoever last edited a manifest. The first-party manifests already followed a consistent shape covering resource bounds, privilege, capabilities, and image tags, but that shape was convention, not a contract, and nothing surfaced a single view of a running cluster's compliance. The conventions needed to become machine-checked policy with one source of truth shared between the cluster and CI.

## Decision

Adopt Kyverno as the policy engine and codify the existing conventions as `ClusterPolicy` resources: resource requests and limits, `runAsNonRoot`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, and a fixed image tag that is never `:latest`. They are adapted from Kyverno's pod-security and best-practices library rather than hand-authored. Kyverno installs as a Flux HelmRelease in a dedicated `kyverno` namespace with background scanning and policy reports enabled, so compliance is evaluated continuously rather than only at admission. The same resources are the single source of policy truth for CI, where one job runs `kyverno test` against authored unit tests and then `kyverno apply` of the policies against the rendered first-party manifests, failing the build on any violation.

All five validation policies carry `validationFailureAction: Enforce` cluster-wide, and scope is expressed in two other places. Whole namespaces are exempted through the Kyverno HelmRelease values `config.webhooks.namespaceSelector` and `config.resourceFiltersIncludeNamespaces`, which between them exclude kube-system, flux-system, longhorn-system, cert-manager, metallb-system, monitoring, cnpg-system and the Rancher namespaces. Individual workloads are exempted with `PolicyException` resources in `kubernetes/infrastructure/configs/policies/exceptions.yaml`. The namespace exemptions were added for availability rather than compliance, to keep a Kyverno outage from blocking pod admission in the namespaces needed to recover from one.

Getting there was audit-first. Every policy shipped `validationFailureAction: Audit` so admitting the existing workloads, most of them upstream Helm charts that do not meet the restricted baseline, never broke, and graduation to enforce was decided per namespace through `validationFailureActionOverrides` on the evidence of an offline `kyverno apply`. Only `blog` and `homepage` graduated at first, because their first-party Deployments passed all five policies, and the litellm database-init Job failed four of them, carrying no resource bounds and no security context, until it was corrected to non-root with dropped capabilities and bounded resources. That rollout is finished and the mechanism it used is gone: the overrides appear nowhere in the tree and `blog` and `homepage` hold no special status.

Policy Reporter installs as a second HelmRelease in the same namespace for reporting. Its Prometheus metrics exporter and Kyverno plugin are enabled, its ServiceMonitor carries the `release: kube-prometheus-stack` label, and its Grafana dashboards render into the `monitoring` namespace through the sidecar label. Its own UI is disabled and carries no route, so PolicyReports are read through Grafana and `kubectl` rather than through a dashboard of its own.

## Options considered

- Kyverno, chosen. Policies are Kubernetes-native YAML, so the same resource drives admission control, background audit, and the CI gate with no second language, and it emits native `PolicyReport` resources that render into a UI and Prometheus metrics.
- OPA Gatekeeper. Rejected. Policies are written in Rego, a separate language to learn and test, which splits the source of truth between the cluster and any shift-left check, and its reporting ecosystem is thinner than the PolicyReport path.
- Keep the scanner sweep from [0043](0043-triage-production-readiness-findings.md) and add no admission control. Rejected. A periodic off-cluster scan catches drift late, cannot stop a non-compliant Pod from admitting, and leaves the conventions as prose.

## Consequences

The conventions are a contract. A workload that drops a resource limit, runs as root, or floats to `:latest` is rejected at admission, and the same violation fails CI before it merges, because both read the one policy set. The consequence worth stating plainly is that a namespace passing policy no longer implies its workloads comply. Several pass only because the webhook never evaluates them, and unlike the audit-first model those gaps do not surface as PolicyReports at all. Any future move to label those namespaces under Pod Security Admission has to account for that, because a PSA label carries no equivalent exemption. The standing costs are two more controllers to keep current and an exemption list whose entries have to be revisited as the reason for each one expires.

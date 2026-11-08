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
- Reading Secrets in every namespace is allowlisted in git. `scripts/check-manifests.sh` fails CI when a ClusterRoleBinding, directly or through an aggregated ClusterRole, lets a subject outside `cluster_secret_readers` get, list or watch Secrets, and when a RoleBinding does the same in `flux-system`, `longhorn-system` or `postgres`, whose Secrets unlock the rest of the estate. Each entry needs it:
  - `cert-manager/cert-manager` writes certificate Secrets wherever a Certificate lives, and `cert-manager/cert-manager-cainjector` reads them to inject CA bundles into webhooks and CRDs.
  - `cnpg-system/cloudnative-pg` manages the superuser, replication and role password Secrets of the Postgres cluster, and `cnpg-system/plugin-barman-cloud` reads the R2 credentials an ObjectStore references.
  - `flux-system/flux-operator` holds cluster-admin to install and run the Flux controllers, which apply every manifest including Secrets.
  - `longhorn-system/longhorn-service-account` and `longhorn-system/longhorn-support-bundle` are the Longhorn manager, which reads volume encryption and backup target Secrets, and its support bundle collector.
  - `monitoring/kube-prometheus-stack-operator` reads the Secrets that monitors and Alertmanager configs reference and writes the generated Prometheus and Alertmanager configuration Secrets.
- Every other controller is scoped to the namespaces it serves. Grafana's sidecars read ConfigMaps in `monitoring` through a hand-written Role, Reloader and Traefik get chart Roles in the namespaces they list, Flagger runs on a hand-written ClusterRole without Secrets, and Loki, Alloy and kube-state-metrics do not touch Secrets. The chart defaults are overridden because they grant more: Flagger's chart RBAC reads and writes Secrets in every namespace, Alloy's default rules read Secrets for `remote.kubernetes` although the config only runs `discovery.kubernetes`, and Loki's chart grants Secret read with the rules sidecar whatever its resource setting, so the sidecar stays off while no `loki_rule` object exists.

## Consequences

- A workload that violates policy fails at admission with the rule named in the error, so new apps set `runAsNonRoot`, a user ID and resources from the start. The scaffold does this by default ([0013](0013-keep-each-app-self-contained-and-scaffold-new-ones.md)).
- The skipped namespaces carry no admission guarantee, which is the price of keeping storage, DNS, certificates and GitOps out of Kyverno's blast radius.
- Excluding a resource later leaves stale failures in existing policy reports until the reports are deleted and rebuilt.
- A namespace with an IngressRoute, Middleware or Reloader annotation must be listed in the Traefik or Reloader values, or its routes and restarts stop working; the scaffold adds new apps to both.
- Traefik reads every Secret in the namespaces it watches, because its Secret informer lists whole namespaces and the chart's `rbac.secretResourceNames` breaks that informer. It therefore watches neither `flux-system` nor `longhorn-system`: the Flux and Longhorn UI routes live in the `traefik` namespace and reach their backends through ExternalName Services, and the homepage tiles for them check the site instead of the pods and are marked external, because homepage looks for pods in the route's own namespace.

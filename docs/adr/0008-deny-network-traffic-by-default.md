---
status: accepted
date: 2026-11-07
---

# 0008. Deny network traffic by default

## Context

Every namespace runs software from upstream images, and some of it reaches the internet. Without policy, any compromised pod can reach every database, admin UI and node on the LAN. The cluster enforces NetworkPolicy through the kube-router controller embedded in K3s.

## Decision

- Every namespace starts from `default-deny` for ingress and egress plus `allow-dns` to CoreDNS. The Kyverno ClusterPolicy `generate-network-policies` creates both in every namespace, including new ones, and keeps them in sync, so a namespace cannot exist without them. Deleting the policy leaves the generated objects in place.
- `kube-system` is the one namespace with no baseline at all: CoreDNS serves every namespace from there, and a default-deny without its allow set takes cluster DNS down.
- The generate rules also exclude by name every namespace named in Kyverno's resource filters (`kube-public`, `kube-node-lease`, `flux-system`, `kyverno`, `cnpg-system`, `cert-manager`, `longhorn-system`, `metallb-system`, `monitoring`), so generation does not depend on how those filters treat Namespace objects. These namespaces carry Flux-managed copies from `kubernetes/components/network-policies/default-deny` and `kubernetes/components/network-policies/base`, next to their own allow set. `scripts/check-manifests.sh` fails when the excluded list drifts from the filters in the rendered Kyverno chart, or when a namespace is neither generated into nor declares both policies.
- The policy is built so that neither Kyverno nor Flux can strip a baseline by accident. It sets `failurePolicy: Ignore`, because a `Fail` webhook on Namespace writes would hold `cluster-namespaces` not-Ready during a Kyverno outage, and `cluster-security`, which deploys Kyverno, depends on it. It uses server-side apply, so a copy Flux also manages keeps Flux's labels and is co-owned rather than overwritten back and forth. `orphanDownstreamOnPolicyDelete` keeps the generated objects when the policy is deleted or reverted. Each generated object carries `kustomize.toolkit.fluxcd.io/prune: disabled`, because Flux reads that annotation on the live object before pruning: dropping a former Flux copy from git then leaves the generated one in place instead of deleting it.
- `kubernetes/components/network-policies/base` still carries `allow-dns` for the namespaces that used it before generation, until the generated copy is proven everywhere. Further traffic is allowed by small reusable components: `intra-namespace`, `internet-egress` (80 and 443 to `0.0.0.0/0` with the pod, service, VLAN 20, VLAN 30 and home LAN ranges excluded) and `traefik-ingress`.
- Monitoring reach follows the workload. Prometheus alone has scrape egress, on the listed scrape ports, and every other monitoring pod has one egress rule per peer it needs. Port 9500 on longhorn-manager is the whole unauthenticated Longhorn API, not only metrics, so it admits Prometheus pods only. Traefik reaches Grafana, Prometheus, Alertmanager and Alloy on one port each, and Alloy's 4317 is where Traefik sends traces.
- Shared services grant access by namespace label rather than by a list in their own policy. `bedrock.io/traefik-routable` lets Traefik route to a namespace, and `bedrock.io/postgres-client` opens port 5432 on the Postgres instances. An app opts in from its own `namespace.yaml`.
- A policy port names the port the pod listens on, never the Service port, and a named container port is preferred over a number so the policy follows the container when the number changes.
- A Job or CronJob that calls another service first waits for that service to accept a TCP connection, through the `kubernetes/components/wait-for-dependencies` init container, with targets in the `bedrock.io/wait-for` pod annotation and a 120 second deadline. kube-router admits a new pod's IP into the target's allow rules only seconds after the pod starts, and a Job that connects at once is refused.

## Consequences

- A new app reaches nothing it has not declared, and the declaration sits in the app's own folder.
- A deleted `default-deny` comes straight back while the policy synchronizes, so restoring traffic in an emergency means adding a temporary allow policy, never deleting the baseline. The kyverno namespace fallback is in `docs/admission-break-glass.md`.
- A denied connection shows up as connection refused, not a timeout, which reads like a dead service. The check is to repeat the request from a namespace that is allowed.
- A policy written against a Service port silently blocks the traffic it was meant to allow.
- Long-running pods tolerate the admission delay through their normal retries; only one-shot clients need the wait.

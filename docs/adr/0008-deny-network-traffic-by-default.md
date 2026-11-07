---
status: accepted
date: 2026-11-07
---

# 0008. Deny network traffic by default

## Context

Every namespace runs software from upstream images, and some of it reaches the internet. Without policy, any compromised pod can reach every database, admin UI and node on the LAN. The cluster enforces NetworkPolicy through the kube-router controller embedded in K3s.

## Decision

- Every namespace starts from `default-deny` for ingress and egress plus DNS to CoreDNS, from `kubernetes/components/network-policies/base`. Further traffic is allowed by small reusable components: `intra-namespace`, `internet-egress` (80 and 443 to public addresses only, with the pod, service, VLAN and home LAN ranges excluded) and `traefik-ingress`.
- Shared services grant access by namespace label rather than by a list in their own policy. `bedrock.io/traefik-routable` lets Traefik route to a namespace, and `bedrock.io/postgres-client` opens port 5432 on the Postgres instances. An app opts in from its own `namespace.yaml`.
- A policy port names the port the pod listens on, never the Service port, and a named container port is preferred over a number so the policy follows the container when the number changes.
- A Job or CronJob that calls another service first waits for that service to accept a TCP connection, through the `kubernetes/components/wait-for-dependencies` init container, with targets in the `bedrock.io/wait-for` pod annotation and a 120 second deadline. kube-router admits a new pod's IP into the target's allow rules only seconds after the pod starts, and a Job that connects at once is refused.

## Consequences

- A new app reaches nothing it has not declared, and the declaration sits in the app's own folder.
- A denied connection shows up as connection refused, not a timeout, which reads like a dead service. The check is to repeat the request from a namespace that is allowed.
- A policy written against a Service port silently blocks the traffic it was meant to allow.
- Long-running pods tolerate the admission delay through their normal retries; only one-shot clients need the wait.

---
status: accepted
date: 2026-06-23
---

# 0053. Make the critical path survive a single node loss

## Context

A single unplugged patch-panel cable to worker-2 took down all ingress and authentication. The data was never at risk, because Longhorn keeps three replicas of every volume across the three nodes. The outage happened because the critical-path workloads were each a single replica, several of them happened to sit on worker-2, and nothing rescheduled them.

Three separate weaknesses combined. Traefik, the Authentik server and worker, and the CloudNativePG cluster from [0046](0046-cloudnative-pg-declarative-postgres.md) all ran with one replica, so the loss of whichever node held them was a full outage of that service. Longhorn's `node-down-pod-deletion-policy` was left at `do-nothing`, so a pod stranded on a dead node was never deleted and Kubernetes never rescheduled it. And the node firewall had never opened MetalLB's memberlist port 7946, a latent gap that broke leader election the moment the nodes were rebuilt during the same maintenance window. The firewall fix is recorded with the MetalLB work; this record covers the workload topology.

## Decision

Make every critical-path service tolerate the loss of any one node, and let stranded stateful pods reschedule on their own.

Longhorn's `nodeDownPodDeletionPolicy` is set to `delete-both-statefulset-and-deployment-pod`. When a node goes away, its orphaned pods are deleted so the scheduler can place them on a healthy node, where Longhorn reattaches the volume from a surviving replica.

Traefik runs two replicas with a required pod anti-affinity on `kubernetes.io/hostname` and a PodDisruptionBudget allowing one disruption, so the two ingress pods always land on different nodes. CloudflareD gains the same required anti-affinity and a budget, replacing the spread it had only by luck. The Authentik server and worker each run two replicas; the chart already ships a preferred per-component anti-affinity, which spreads them reliably on a three-node cluster with headroom, and each component gets a budget. The Authentik Redis stays a single replica on purpose: it holds only cache and broker state, has no persistent volume, and reschedules immediately on node loss, so a sentinel deployment would be cost without benefit.

The CloudNativePG cluster scales from one instance to three with a preferred anti-affinity, giving one primary and two streaming standbys with automatic failover, one per node. Going multi-instance exposed a second gap: the namespace NetworkPolicies, written for a single instance, permitted PostgreSQL traffic only from client namespaces, not between the database pods themselves. The new replicas could not reach the primary on 5432 and hung in basebackup. The ingress and egress policies now also allow port 5432 between pods labelled `cnpg.io/cluster=postgres`.

Monitoring and DNS are left as they are, by design. Loki and Tempo stay single-replica: neither can run multiple replicas without an object-storage backend, which is a larger change disproportionate to logs and traces, and the Longhorn policy above now gives them automatic reschedule on node loss, which is the right trade-off for observability. CoreDNS stays at one replica on master. It is a k3s-managed addon rather than a Helm release, it reschedules on node loss on its own, and scaling it cleanly would mean either an HPA flooring the replica count or owning a full manifest override, neither of which earns its fragility for a service that already recovers quickly.

## Options considered

- Required versus preferred anti-affinity. Required is used where the chart exposes affinity directly (Traefik, CloudflareD) to guarantee spread on the small cluster. Preferred is accepted for Authentik, where it is the chart default and reliably spreads two replicas across three nodes, and for CloudNativePG, where it lets the operator re-home an instance onto a surviving node during a node-down event instead of leaving it pending.
- Pinning critical workloads off worker-2 with a taint. Rejected. The node was only ever offline because of a cabling mistake, not instability, and spreading replicas with anti-affinity protects against the loss of any node rather than singling one out.
- Multi-replica Loki and Tempo. Deferred. It requires migrating their storage to an object store and is out of proportion to the value; the reschedule behaviour is enough.
- Scaling CoreDNS with an HPA or a manifest override. Declined for now in favour of leaving the single addon replica on master.

## Consequences

The cluster now serves ingress, authentication, and its database through the loss of any single node. Resource use rises with the extra replicas, comfortably within the nodes' headroom. Any future change to the number of CloudNativePG instances depends on the replication NetworkPolicy staying in place; removing the port 5432 intra-cluster rule would silently break replica joins again. DNS and the monitoring backends still see a brief gap on node loss while their single pods reschedule, which is accepted.

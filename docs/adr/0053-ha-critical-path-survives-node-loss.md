---
status: accepted
date: 2026-06-23
---

# 0053. Make the critical path survive a single node loss

## Context

A single unplugged patch-panel cable to worker-2 took down all ingress and authentication. The data was never at risk, because Longhorn keeps three replicas of every volume across the three nodes. The outage happened because three weaknesses combined. Traefik, the Authentik server and worker, and the CloudNativePG cluster from [0046](0046-cloudnative-pg-declarative-postgres.md) all ran with one replica, so losing whichever node held them was a full outage of that service. Longhorn's `node-down-pod-deletion-policy` was left at `do-nothing`, so a pod stranded on a dead node was never deleted and Kubernetes never rescheduled it. And the node firewall had never opened MetalLB's memberlist port 7946, a latent gap that broke leader election the moment the nodes were rebuilt during the same maintenance window. The firewall fix is recorded with the MetalLB work; this record covers the workload topology.

## Decision

Make every critical-path service tolerate the loss of any one node, and let stranded stateful pods reschedule on their own. Longhorn's `nodeDownPodDeletionPolicy` is set to `delete-both-statefulset-and-deployment-pod`, so when a node goes away its orphaned pods are deleted, the scheduler places them on a healthy node, and Longhorn reattaches the volume from a surviving replica.

Traefik runs two replicas with a required pod anti-affinity on `kubernetes.io/hostname` and a PodDisruptionBudget allowing one disruption, so the two ingress pods always land on different nodes. CloudflareD gains the same required anti-affinity and a budget, replacing the spread it had only by luck. The Authentik server runs two replicas with the chart's preferred per-component anti-affinity, which spreads them reliably on a three-node cluster, and a budget of its own. The Authentik worker and the Authentik Redis stay single-replica on purpose: the worker's jobs are queued and resumed rather than served, and Redis holds only cache and broker state with no persistent volume, so both reschedule on node loss and neither carries a disruption budget, which on a single replica could only ever allow or forbid the eviction outright.

The CloudNativePG cluster scales from one instance to three with a preferred anti-affinity, giving one primary and two streaming standbys with automatic failover, one per node. Going multi-instance exposed a second gap: the namespace NetworkPolicies, written for a single instance, permitted PostgreSQL traffic only from client namespaces and not between the database pods themselves, so the new replicas could not reach the primary on 5432 and hung in basebackup. The ingress and egress policies now also allow port 5432 between pods labelled `cnpg.io/cluster=postgres`. Loki and Tempo stay single-replica, because neither runs multiple replicas without an object-storage backend, and the Longhorn policy above gives them automatic reschedule, which is the right trade for observability. CoreDNS was also left single-replica here and was made highly available later by [0065](0065-coredns-flux-high-availability.md).

## Options considered

- Required versus preferred anti-affinity. Required is used where the chart exposes affinity directly, for Traefik and CloudflareD, to guarantee spread on the small cluster. Preferred is accepted for Authentik, where it is the chart default, and for CloudNativePG, where it lets the operator re-home an instance onto a surviving node during a node-down event instead of leaving it pending.
- Pinning critical workloads off worker-2 with a taint. Rejected. The node was only ever offline because of a cabling mistake, not instability, and spreading replicas with anti-affinity protects against the loss of any node.
- Multi-replica Loki and Tempo. Deferred. It requires migrating their storage to an object store and is out of proportion to the value; the reschedule behaviour is enough.

## Consequences

The cluster serves ingress, authentication, and its database through the loss of any single worker node. Failure injection confirmed it: powering off either worker kept ingress serving and failed the CloudNativePG primary over in about 29 seconds with writes never stopping. Resource use rises with the extra replicas, comfortably within the nodes' headroom.

Powering off the control-plane node is a different case, and the difference is structural rather than a placement mistake. It took down both the databases and all external access, for two reasons that no amount of replication inside the cluster can fix while there is one API server:

- CloudNativePG's instance manager reads the Cluster resource from the Kubernetes API to learn its role before it starts Postgres. With the API server gone, every instance on every node retried `get cluster` and never started a postmaster, so all three databases were unwritable even though the primary sat on a surviving worker.
- MetalLB's speaker needs the API to see Services. It went blind and stopped announcing, so nothing answered ARP for the load balancer address. Traefik and the application pods were healthy and simply unreachable. A reboot the same day refined this: the address kept serving for about fifty seconds before failing for about seventy-five, so the speaker announces for roughly a minute after the API server goes and unreachable throughout describes a power cycle rather than a reboot.

The honest scope of this record is therefore single worker loss, and closing the control-plane gap needs a three-server control plane, which is tracked separately and deferred. One dependency carries forward: any future change to the number of CloudNativePG instances relies on the replication NetworkPolicy staying in place, since removing the port 5432 intra-cluster rule would silently break replica joins again.

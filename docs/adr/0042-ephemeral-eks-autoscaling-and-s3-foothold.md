---
status: accepted
date: 2026-06-19
---

# 0042. Run AWS as an ephemeral autoscaling EKS cluster with an S3 backup foothold

## Context

AWS in this homelab is for learning the ecosystem and demonstrating multi-cloud GitOps, not a full-time production dependency. Student credits cover it now and will end. An EKS control plane bills about 73 USD per month for as long as it exists, independent of node count, and EKS cannot scale the cluster itself to zero. So an EKS cluster left running is a standing cost for a capability that is used occasionally.

The pieces are already in place: CAPA and Rancher Turtles are deployed and Ready, and an `aws-1` definition (a CAPA managed EKS control plane plus a managed node group) exists under `kubernetes/clusters/home/infrastructure/cluster-api/aws-1/`. It is orphaned, referenced by no kustomization, so nothing is live and there is no cost today. Unlike Hetzner, AWS does expose a managed control plane, so Cluster API models something real here, which is why [0041](0041-hetzner-autoscaling-native-provider.md) keeps CAPI for AWS while dropping it for Hetzner.

## Decision

Provision AWS through CAPA, run the EKS cluster as an ephemeral on-demand resource, autoscale it with the cluster-autoscaler `aws` provider on a CAPA-managed node group, and keep one always-on S3 bucket as a backup foothold.

CAPA owns the cluster lifecycle. `aws-1` is wired into Flux so its `AWSManagedControlPlane` and one managed node group reconcile from Git. The cluster is treated as disposable: deleting the manifests tears down the control plane and nodes to near-zero idle cost, and re-applying rebuilds it in roughly ten minutes. The idle lever is teardown, not node scale-to-zero, because the control-plane fee, not node count, is the dominant cost. The node group carries `minSize`/`maxSize` in Git as the scaling bounds and the `cluster.x-k8s.io/replicas-managed-by: external-autoscaler` annotation so CAPA stops owning the replica count.

The autoscaler is the cluster-autoscaler with the `aws` cloud provider, running inside the EKS cluster, adjusting the managed node group's desired count within its bounds. This keeps the worker layer fully CAPI-declarative: CAPA owns the node group, the autoscaler owns the count, one mental model. The autoscaler bootstraps into EKS through the existing gitops-peer ClusterResourceSet and the `kubernetes/peers` overlay from [0035](0035-standalone-gitops-managed-cloud-cluster.md), so the cluster reconciles its own autoscaler with no push from the home cluster and no horizon involvement. Workload identity uses EKS Pod Identity rather than IRSA, so role trust survives the teardown and recreate cycle without re-templating on each rebuild.

One always-on AWS footprint remains regardless of whether EKS is up: an S3 bucket as a secondary Velero backup target alongside the existing Hetzner object storage from [0009](0009-velero-backups.md). It costs a few cents per month, gives genuine cross-provider backup coverage, exercises real S3 and IAM, and stays demonstrable after the credits end. The only standing AWS resources are this bucket and the account-global IAM.

This updates the AWS posture of [0036](0036-aws-via-managed-eks-control-plane.md) with concrete numbers and adds the autoscaler, the ephemerality rule, the Pod Identity choice, and the S3 foothold.

## Options considered

- CAPA plus cluster-autoscaler `aws` on a managed node group, chosen. It keeps AWS on the same declarative CAPI backbone already deployed, needs a small IAM surface, and is sufficient for a lab that bursts occasionally.
- Karpenter. It is the modern EKS default, but it provisions raw EC2 and bypasses CAPA's node groups entirely, which adds a parallel non-CAPI worker path and the largest IAM surface for bin-packing value a small cluster does not need. EKS Auto Mode adds a per-node fee and removes node-level control. Reserved for a future large or spot-heavy AWS workload.
- Crossplane or an OpenTofu controller for provisioning. Each adds a second infrastructure reconciliation engine and its own state and credentials to do what CAPA already does here.
- A long-running EKS cluster scaled to zero nodes. This does not address the control-plane fee, which is billed whenever the cluster exists, so it saves little over teardown while keeping the cluster exposed.

## Consequences

AWS becomes demonstrable and reproducible on demand at near-zero idle cost, with the cluster fully described in Git and rebuilt in minutes. The worker layer stays CAPI-consistent through CAPA plus the `aws` autoscaler, and Pod Identity keeps controller trust stable across rebuilds. The S3 bucket gives cross-provider backup coverage that outlives both the EKS cluster and the credits. The standing costs are an account-global IAM bootstrap through `clusterawsadm` plus the autoscaler role, and a bitrot tax: an EKS cluster brought up only occasionally drifts from current EKS and CAPA versions, so each spin-up after a long gap needs a manifest refresh. As with Hetzner, the autoscaler must be verified with a scale-from-zero test against the running cluster before this is considered done.

---
status: accepted
date: 2026-06-19
---

# 0042. Run AWS as an ephemeral autoscaling EKS cluster with an ephemeral S3 backup demo

## Context

AWS in this homelab is for learning the ecosystem and demonstrating multi-cloud GitOps, not a full-time production dependency. Student credits cover it now and will end. An EKS control plane bills about 73 USD per month at the 0.10 USD per hour standard-support rate for as long as it exists, independent of node count, and EKS cannot scale the cluster itself to zero. A version that has aged into extended support bills 0.60 USD per hour, six times as much. So an EKS cluster left running is a standing cost for a capability that is used occasionally, and an outdated one is far worse.

The pieces are already in place: CAPA and Rancher Turtles are deployed and Ready, and an `aws-1` definition (a CAPA managed EKS control plane plus a managed node group) exists under `kubernetes/clusters/home/infrastructure/cluster-api/aws-1/`. It is orphaned, referenced by no kustomization, so nothing is live and there is no cost today. Unlike Hetzner, AWS does expose a managed control plane, so Cluster API models something real here, which is why [0041](0041-hetzner-autoscaling-native-provider.md) keeps CAPI for AWS while dropping it for Hetzner.

## Decision

Provision AWS through CAPA, run the EKS cluster as an ephemeral on-demand resource, autoscale it with the cluster-autoscaler `aws` provider on a CAPA-managed node group, and run an S3 backup target as an equally ephemeral demo that follows the same enable, prove, teardown cycle.

CAPA owns the cluster lifecycle. `aws-1` is wired into Flux through a dedicated `cluster-capi-aws` Kustomization that is suspended by default in Git, so its `AWSManagedControlPlane` and one managed node group stay fully declared but inert until a stand-up resumes them. Keeping the toggle in its own Kustomization rather than folding `aws-1` into the shared CAPI tree means suspending AWS never touches the Hetzner control plane or the CAPI core. The cluster is treated as disposable: deleting the live objects tears down the control plane and nodes to near-zero idle cost, and resuming the Kustomization rebuilds it in roughly ten minutes. The idle lever is teardown, not node scale-to-zero, because the control-plane fee, not node count, is the dominant cost. The control plane is pinned to EKS v1.33 to stay in standard support, since the earlier v1.31 pin had aged into extended support at six times the hourly rate. The node group carries `minSize`/`maxSize` in Git as the scaling bounds and the `cluster.x-k8s.io/replicas-managed-by: external-autoscaler` annotation so CAPA stops owning the replica count.

The autoscaler is the cluster-autoscaler with the `aws` cloud provider, running inside the EKS cluster, adjusting the managed node group's desired count within its bounds. This keeps the worker layer fully CAPI-declarative: CAPA owns the node group, the autoscaler owns the count, one mental model. The autoscaler bootstraps into EKS through the existing gitops-peer ClusterResourceSet and the `kubernetes/peers` overlay from [0035](0035-standalone-gitops-managed-cloud-cluster.md), so the cluster reconciles its own autoscaler with no push from the home cluster and no horizon involvement. Workload identity uses IRSA through `associateOIDCProvider: true` on the control plane. CAPA v2.11 has no declarative field for EKS Pod Identity associations, so Pod Identity would require an out-of-band association command on every rebuild and could not live in Git. IRSA keeps the autoscaler fully declarative, with its service-account role annotation pinned in the manifests, at the cost of refreshing the role trust policy to the new OIDC issuer each time the cluster is rebuilt.

The S3 backup target is also ephemeral rather than always-on. It is a secondary Velero backup location alongside the existing Hetzner object storage from [0009](0009-velero-backups.md), declared in Git through its own `cluster-velero-aws-demo` Kustomization that is suspended by default. A stand-up resumes it to prove a real cross-provider backup to S3, then teardown empties and deletes the bucket and re-suspends the Kustomization. This exercises real S3 and IAM on demand without leaving standing AWS resources, which matches the rest of the stack and means the only resource that outlives a cycle is the account-global IAM bootstrap.

This updates the AWS posture of [0036](0036-aws-via-managed-eks-control-plane.md) with concrete numbers and adds the autoscaler, the ephemerality rule, the IRSA workload-identity choice, and the ephemeral S3 backup demo.

## Options considered

- CAPA plus cluster-autoscaler `aws` on a managed node group, chosen. It keeps AWS on the same declarative CAPI backbone already deployed, needs a small IAM surface, and is sufficient for a lab that bursts occasionally.
- Karpenter. It is the modern EKS default, but it provisions raw EC2 and bypasses CAPA's node groups entirely, which adds a parallel non-CAPI worker path and the largest IAM surface for bin-packing value a small cluster does not need. EKS Auto Mode adds a per-node fee and removes node-level control. Reserved for a future large or spot-heavy AWS workload.
- Crossplane or an OpenTofu controller for provisioning. Each adds a second infrastructure reconciliation engine and its own state and credentials to do what CAPA already does here.
- A long-running EKS cluster scaled to zero nodes. This does not address the control-plane fee, which is billed whenever the cluster exists, so it saves little over teardown while keeping the cluster exposed.

## Consequences

AWS becomes demonstrable and reproducible on demand at near-zero idle cost, with the whole stack fully described in Git and rebuilt in minutes. The worker layer stays CAPI-consistent through CAPA plus the `aws` autoscaler. IRSA keeps the autoscaler declarative across rebuilds, at the price of refreshing its role trust policy to the new OIDC issuer each spin-up. The S3 demo proves cross-provider backup coverage on demand and then tears itself down, so nothing AWS-side bills between cycles. The only standing cost is an account-global IAM bootstrap through `clusterawsadm` plus the autoscaler role, both free. There is a bitrot tax: a stack brought up only occasionally drifts from current EKS and CAPA versions and from the pinned addon builds, so each spin-up after a long gap needs a manifest refresh, including resolving the addon versions and the version pin against the standard-support window. The dominant teardown risk is a forgotten control plane or a leftover NAT gateway in the CAPA-managed VPC, so teardown deletes the Cluster object rather than only suspending Flux. As with Hetzner, the autoscaler must be verified with a scale-from-zero test against the running cluster before this is considered done.

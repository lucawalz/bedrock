---
status: accepted, Hetzner backup premise superseded by 0081
date: 2026-06-21
---

# 0049. Remove the AWS multi-cloud build and keep backups on Hetzner

## Context

The AWS work across [0035](0035-standalone-gitops-managed-cloud-cluster.md), [0036](0036-aws-via-managed-eks-control-plane.md), [0042](0042-ephemeral-eks-autoscaling-and-s3-foothold.md), and [0047](0047-multi-cluster-cd-to-eks-peer.md) built a managed EKS cluster reconciled by its own GitOps peer, ran it as an ephemeral autoscaling cluster, and delivered the blog to it behind an ALB. It served its purpose: the multi-cluster continuous-delivery story was proven end to end and captured for write-up, and the cluster was always meant to be torn down afterward. Two facts settled how far the teardown should go. There was no AWS S3 backup in use, since Velero had backed up to Hetzner object storage since [0009](0009-velero-backups.md) and the only S3 reference was an ephemeral demo backup location pointing at a bucket that no longer existed. And the gitops-peer ClusterResourceSet from [0035](0035-standalone-gitops-managed-cloud-cluster.md) had no remaining consumer, because Hetzner scaling joined nodes to the existing cluster rather than running a separate GitOps peer.

## Decision

Remove the AWS footprint entirely and keep no standing AWS dependency. Delete the EKS cluster definition, the CAPA infrastructure provider, the AWS bootstrap credentials, the capa-system namespace, the EKS blog overlay, the peer payload, and the ephemeral S3 backup location. Remove the gitops-peer ClusterResourceSet as well, since nothing uses it. Finish the stuck cluster deletion by hand where a leaked load-balancer security group blocked the VPC teardown, then delete the CAPA bootstrap stack and the cluster-autoscaler IAM role it left behind. Backups stay on Hetzner object storage as decided in [0009](0009-velero-backups.md), and the Flagger progressive delivery in [0048](0048-flagger-progressive-delivery.md) runs on the home cluster against Traefik metrics and is unaffected.

## Options considered

- Keep an AWS S3 backup location alongside Hetzner for off-site redundancy. Rejected: it was never wired up, off-site redundancy is a separate decision to make on its own merits, and keeping it means a standing IAM and billing relationship for no current benefit.
- Keep the gitops-peer primitive in place for a future standalone peer. Rejected as speculative; it is small and well documented in [0035](0035-standalone-gitops-managed-cloud-cluster.md), so it can be reintroduced if a real second cluster returns.
- Suspend the AWS Flux Kustomizations and leave the manifests in the repo. Rejected: suspended-but-present manifests read as live infrastructure, drift from reality, and keep failing report locations and dangling references in the tree.

## Consequences

The repository describes what actually runs, with no AWS account dependency and nothing billing. The proven multi-cloud capability is preserved as history in these records, so it can be rebuilt rather than left running, and reintroducing a cloud peer later means restoring the provider, credentials, and gitops-peer rather than un-suspending dormant manifests. Everything this record kept on the Hetzner side has since gone. The autoscaler behind the CAPH scaling premise was retired by [0062](0062-retire-elastic-cluster-autoscaler.md) and the remaining Cluster-API-for-Hetzner stack by [0063](0063-return-to-single-region.md). Velero, the Longhorn backup target, the etcd snapshot upload and the CloudNativePG archiver all went with the account under [0081](0081-retire-the-hetzner-account.md), which added no off-site substitute. What survives from this record is the AWS teardown itself and the conclusion the CAPH sentence supported, that the gitops-peer ClusterResourceSet has no consumer. The rejected off-site AWS bucket also survives as a rejection: it remains a decision to make on its own merits rather than one this record left open.

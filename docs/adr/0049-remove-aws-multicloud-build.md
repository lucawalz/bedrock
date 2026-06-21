---
status: accepted
date: 2026-06-21
---

# 0049. Remove the AWS multi-cloud build and keep backups on Hetzner

## Context

The AWS work across ADRs 0035, 0036, 0042, and 0047 built a managed EKS cluster reconciled by its own GitOps peer, ran it as an ephemeral autoscaling cluster, and delivered the blog to it as a live second cluster behind an ALB. It served its purpose: the multi-cluster continuous-delivery story was proven end to end and captured for write-up, and the working state is tagged `v0.1.0-multicloud-cd` for recovery. The cluster was always meant to be torn down once that was done.

Two facts settled how far the teardown should go. There is no AWS S3 backup in use: Velero has backed up to Hetzner object storage since ADR 0009, and the only S3 reference was the ephemeral demo backup location from 0042, which pointed at a bucket that no longer exists. And the gitops-peer ClusterResourceSet from 0035 has no remaining consumer, because Hetzner scaling joins nodes to the existing cluster through CAPH rather than running a separate GitOps peer.

## Decision

Remove the AWS footprint entirely and keep no standing AWS dependency. Delete the EKS cluster definition, the CAPA infrastructure provider, the AWS bootstrap credentials, the capa-system namespace, the EKS blog overlay, the peer payload under kubernetes/peers, and the ephemeral S3 backup location. Remove the gitops-peer ClusterResourceSet as well, since nothing uses it. Finish the stuck cluster deletion by hand where a leaked load-balancer security group blocked the VPC teardown, then delete the CAPA CloudFormation bootstrap stack and the cluster-autoscaler IAM role it left behind.

Backups stay on Hetzner object storage as decided in ADR 0009; nothing about Velero changes. Long-term cloud scaling stays on Hetzner through the native CAPH autoscaler (ADRs 0024, 0025, 0041). The Flagger progressive-delivery work (ADR 0048) runs on the home cluster against Traefik metrics and is unaffected.

## Options considered

- Keep an AWS S3 backup location alongside Hetzner for off-site redundancy. Rejected: it was never actually wired up, off-site redundancy is a separate decision to make on its own merits, and keeping it means a standing IAM and billing relationship for no current benefit.
- Keep the gitops-peer primitive in place for a future standalone peer. Rejected as speculative; it is small and well documented in 0035, so it can be reintroduced if a real second cluster returns.
- Suspend the AWS Flux Kustomizations and leave the manifests in the repo. Rejected: suspended-but-present manifests read as live infrastructure, drift from reality, and keep failing report locations and dangling references in the tree.

## Consequences

The repository describes what actually runs: home K3s, Hetzner burst scaling, and Hetzner-backed backups, with no AWS account dependency and nothing billing. The proven multi-cloud capability is preserved as history in these records and as the `v0.1.0-multicloud-cd` tag, so it can be rebuilt deliberately rather than left running. Reintroducing a cloud peer later means restoring the provider, credentials, and gitops-peer rather than un-suspending dormant manifests, which is the correct cost for standing infrastructure.

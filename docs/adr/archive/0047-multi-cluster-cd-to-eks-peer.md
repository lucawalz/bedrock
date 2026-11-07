---
status: superseded by 0049
date: 2026-06-21
---

# 0047. Deliver the blog to the EKS peer with overlay-based multi-cluster CD

## Context

The home cluster reconciles every workload with Flux from this repository, and [0035](0035-standalone-gitops-managed-cloud-cluster.md) established that a cloud peer self-bootstraps its own Flux from a `bedrock.io/gitops-peer` label rather than being driven from home. [0042](0042-ephemeral-eks-autoscaling-and-s3-foothold.md) made the AWS side an ephemeral, cost-gated EKS cluster suspended by default and resumed only for a demo. What was missing was the delivery path: a way to have an existing workload land on the peer by reconciliation alone, with no manual apply. The blog is the natural payload, being stateless and so carrying no cross-cloud data dependency. This is built for learning and a demo; the AWS side is reverted afterward and restorable from a tag.

## Decision

Refactor the blog into a shared base with per-cluster overlays. `apps/blog/base` holds the Deployment, Service, and image-policy setter; `overlays/home` keeps the current Traefik IngressRoute, MetalLB edge, and cert-manager DNS-01 behaviour; `overlays/eks` expresses the same app for AWS with an `Ingress` of `ingressClassName: alb`. The home cluster reconciles `overlays/home`. The peer's self-bootstrapped Flux reconciles `kubernetes/peers/base`, which carries the AWS Load Balancer Controller so the `alb` class resolves, and references the blog `overlays/eks` and its namespace. When the AWS Kustomization is resumed, the cluster is provisioned, Flux bootstraps on it, and the blog reconciles onto the peer with no migration step. The promotion gate is asymmetric by design: home deploys on every green build through image automation, while the peer deploys only when it exists, which is the cost-gated resume. The blog is stateless, so there is no cross-cloud data seam and stateful promotion is out of scope.

## Options considered

- Per-cluster overlays reconciled by an autonomous peer Flux, chosen. The base stays shared, each cloud's edge differences live in its own overlay, and the workload lands by reconciliation with no manual migration.
- Rancher Fleet from the hub. Rancher is present for Cluster API but does not drive workloads, and adopting Fleet would add a second delivery system beside Flux for no gain on a single peer.
- Hub Flux applying to the peer through a remote kubeconfig. Rejected in [0035](0035-standalone-gitops-managed-cloud-cluster.md): it couples peer health to the home cluster and pushes peer credentials into the home control plane, where peer-autonomous Flux keeps the failure domains separate.

## Consequences

The same application is delivered to a second cloud by GitOps alone, which is the discipline this delivery path was built to demonstrate. The AWS Load Balancer Controller and the ALB ingress are the genuine point where the second cloud leaks into the manifests: the home Traefik, MetalLB, and DNS-01 stack does not carry over, and the overlay split is what contains that difference. The peer also needs per-spin-up AWS setup outside Git, notably an IRSA role whose trust is bound to a cluster OIDC issuer that changes on every rebuild. The entire AWS footprint, including this delivery path, was reverted after the demo by [0049](0049-remove-aws-multicloud-build.md) and is restorable from the tag that marks the working state.

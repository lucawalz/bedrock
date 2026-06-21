---
status: accepted
date: 2026-06-21
---

# 0047. Deliver the blog to the EKS peer with overlay-based multi-cluster CD

## Context

The home cluster reconciles every workload with Flux from this repository, and ADR 0035 established that a cloud peer self-bootstraps its own Flux from a `bedrock.io/gitops-peer` label rather than being driven from the home cluster. ADR 0042 made the AWS side an ephemeral, cost-gated EKS cluster (`aws-1`), suspended by default and resumed only for a demo. What was missing was the delivery path: a way to take an existing workload and have it land on the peer by reconciliation alone, with no manual apply. The blog is the natural payload, and being stateless it carries no cross-cloud data dependency. This is built for learning, the blog post, and a demo; the AWS side is reverted afterward and is restorable from a tag.

## Decision

Refactor the blog into a shared base with per-cluster overlays. `apps/blog/base` holds the Deployment, Service, and image-policy setter. `overlays/home` keeps the current behaviour (Traefik IngressRoute, the MetalLB edge, cert-manager DNS-01); `overlays/eks` expresses the same app for AWS with an `Ingress` of `ingressClassName: alb`. The home cluster's `cluster-apps` reconciles `overlays/home`. The EKS peer's self-bootstrapped Flux reconciles `kubernetes/peers/base`, which carries the AWS Load Balancer Controller so the `alb` class resolves and references the blog `overlays/eks` and its namespace. When `cluster-capi-aws` is resumed, CAPA provisions the cluster, Flux bootstraps on it, and the blog reconciles onto the peer with no migration step.

The promotion gate is asymmetric by design: home deploys on every green build through image automation, while the peer deploys only when it exists, which is the cost-gated resume of `cluster-capi-aws`. The blog is stateless, so there is no cross-cloud data seam; stateful promotion is out of scope.

## Options considered

- Per-cluster overlays reconciled by an autonomous peer Flux, chosen. The base stays shared, each cloud's edge differences live in its own overlay, and the workload lands by reconciliation with no manual migration.
- Rancher Fleet from the hub. Rancher is present for Cluster API through Turtles but does not drive workloads, and adopting Fleet would add a second delivery system beside Flux for no gain on a single peer.
- Hub Flux applying to the peer through a remote kubeconfig. Rejected in ADR 0035: it couples peer health to the home cluster and pushes peer credentials into the home control plane. Peer-autonomous Flux keeps the failure domains separate.

## Consequences

The same application is delivered to a second cloud by GitOps alone, which is the discipline this delivery path was built to demonstrate. The AWS Load Balancer Controller and the ALB ingress are the genuine point where the second cloud leaks into the manifests: the home Traefik, MetalLB, and DNS-01 stack does not carry over, and the overlay split is what contains that difference. The peer also needs per-spin-up AWS setup that lives outside Git, notably an IRSA role whose trust is bound to the cluster OIDC issuer, which changes on every rebuild. The entire AWS footprint, including this delivery path, is reverted after the demo and restorable from the tag that marks the working state; Velero's S3 backup foothold and Hetzner autoscaling are kept.

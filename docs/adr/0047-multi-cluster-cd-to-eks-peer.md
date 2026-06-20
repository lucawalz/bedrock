---
status: accepted
date: 2026-06-21
---

# 0047. Deliver the blog to the EKS peer with overlay-based multi-cluster CD

## Context

The home cluster reconciles every workload with Flux from this repository, and ADR 0035 established that a cloud peer self-bootstraps its own Flux from a `bedrock.io/gitops-peer` label rather than being driven from the home cluster. ADR 0042 made the AWS side an ephemeral, cost-gated EKS cluster (`aws-1`) that is suspended by default and resumed only for a demo. What was missing was the continuous-delivery path itself: a way to take an existing workload and have it land on the peer by reconciliation alone, with no manual apply, and a clear account of where running on a second cloud forces different infrastructure.

The blog is the natural payload. It already has image automation on the home cluster and is stateless, so it carries no cross-cloud data dependency. This work is built for learning, the blog post, and a demo; the AWS portion is reverted afterward to avoid standing cost, recoverable from a tag (see the teardown decision below).

## Decision

Refactor the blog into a shared base with per-cluster overlays. `apps/blog/base` holds the Deployment, Service, and the image-policy setter. `overlays/home` keeps the existing behaviour: a Traefik IngressRoute, the MetalLB-fronted edge, and cert-manager DNS-01. `overlays/eks` expresses the same app for AWS: an `Ingress` with `ingressClassName: alb` and the internet-facing, IP-target annotations the AWS Load Balancer Controller consumes.

The home cluster's `cluster-apps` reconciles `overlays/home`. The EKS peer's self-bootstrapped Flux reconciles `kubernetes/peers/base`, which now carries the AWS Load Balancer Controller (the controller that makes `ingressClassName: alb` resolve) alongside the existing cluster-autoscaler, and references the blog `overlays/eks` plus the blog namespace. When `cluster-capi-aws` is resumed, CAPA provisions the cluster, the ClusterResourceSet installs Flux on it, and the blog reconciles onto the peer with no migration step.

The promotion gate is asymmetric on purpose. Home deploys on every green build through image automation. The peer deploys only when it exists, which is the cost-gated resume of `cluster-capi-aws`. Spin up, reconcile, verify, tear down.

The state boundary is named explicitly: the blog is stateless, so there is no cross-cloud data seam to reconcile. Stateful promotion across clouds is out of scope and deferred.

## Options considered

- Rancher Fleet from the hub. Rancher is present for Cluster API lifecycle through Turtles, but it does not drive workloads here, and adopting Fleet would add a second delivery system beside Flux for no gain on a single peer.
- Hub Flux applying to the peer through a remote kubeconfig. Rejected in ADR 0035: it couples peer health to the home cluster, makes home Flux a single point of failure, and pushes peer credentials into the home control plane. Peer-autonomous Flux keeps the failure domains separate.
- Per-cloud peer overlays now (`peers/aws-base`, `peers/hetzner-base`). Deferred. There is one peer, so `peers/base` stays flat; the split is worth it only when a second peer diverges.

## Consequences

The same application is delivered to a second cloud by GitOps alone, which is the discipline the phase set out to demonstrate. The AWS Load Balancer Controller and the ALB ingress are the genuine point where the second cloud leaks into the manifests: the home Traefik, MetalLB, and DNS-01 stack does not carry over, and the overlay split is what contains that difference.

The blog namespace is duplicated as a self-contained file in `overlays/eks` rather than referenced from the home namespaces tree, because kustomize's default root-only load restriction forbids pulling a bare file across build roots and CI runs a plain `kustomize build`. The cost is one small duplicated manifest, accepted over relaxing the load restrictor repo-wide.

The AWS Load Balancer Controller needs an IRSA role bound to the cluster OIDC issuer; the role name is stable but its trust policy is refreshed each cluster rebuild, so a one-time AWS step accompanies every spin-up. The entire AWS footprint, including this delivery path, is reverted after the demo per the teardown plan and is restorable from the tag that marks the working state. Velero's S3 backup foothold and Hetzner autoscaling are kept.

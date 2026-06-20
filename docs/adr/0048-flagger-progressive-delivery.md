---
status: accepted
date: 2026-06-21
---

# 0048. Canary the blog with Flagger on the Phase 1 Traefik SLIs

## Context

ADR 0044 defined availability and latency SLOs for the blog from Traefik's per-router RED metrics, with multi-burn-rate alerting. Those SLIs were built to become a delivery gate, not just a dashboard. The remaining gap was progressive delivery: rolling a new blog version gradually and rolling it back automatically when it breaches the same objectives that page a human.

The blog is served on the home cluster behind Traefik. The multi-cluster work (ADR 0047) puts a copy on EKS behind an ALB, but the ALB exposes no Prometheus metrics and Flagger has no native ALB analysis provider, whereas Traefik is a first-class Flagger provider. Progressive delivery therefore belongs on the home cluster, where it reuses the Phase 1 metrics directly and is unaffected by the AWS teardown.

## Decision

Run Flagger on the home cluster with the Traefik provider and canary the blog. Flagger creates primary and canary Deployments and Services and a weighted Traefik service; the blog IngressRoute routes through that weighted service. Canary analysis steps traffic in increments and gates each step on two checks expressed as Flagger MetricTemplates against the existing Prometheus: request success rate at or above 99 percent, and p99 request duration at or below 500 milliseconds, matching the objectives in ADR 0044. Breaching the threshold for the configured number of intervals rolls the release back automatically.

The analysis reads per-service Traefik metrics scoped to the canary service, not the per-router metric the SLO rule uses. The router metric aggregates primary and canary traffic and cannot isolate the new version, so the Phase 1 PrometheusRule keeps keying on the router for top-line monitoring while the canary keys on the service for promotion decisions. The IngressRoute keeps its name, so the router label is unchanged and the SLO rule continues to fire as before.

## Options considered

- Flagger on EKS against the ALB. Flagger has no ALB provider; this would require exporting CloudWatch metrics into Prometheus or a custom webhook, abandons the Phase 1 SLI reuse, and would be reverted with the rest of the AWS footprint. Rejected.
- Argo Rollouts. A capable alternative, but Flagger fits the existing Flux and Prometheus grain with no additional CRD-driven controller stack to learn. Rejected on fit, not merit.

## Consequences

The blog gains automated canary releases with rollback gated on the same numbers that define its reliability, closing the loop from ADR 0044. Flagger runs on the home cluster only and is independent of the AWS work, so it survives the teardown and remains a real capability; it is also removable on its own if the maintenance is not wanted.

Two operational notes follow from the Traefik integration. First adoption has a brief window where the IngressRoute points at the weighted service before Flagger has created it, during which the blog can return 404 until the primary is ready; this is one-time and self-heals. Canary analysis needs live or generated traffic, because a metric query over an idle canary returns no data and stalls or fails the step rather than passing it; a load source is part of running a canary, not an afterthought.

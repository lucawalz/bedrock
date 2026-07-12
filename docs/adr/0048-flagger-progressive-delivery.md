---
status: accepted
date: 2026-06-21
---

# 0048. Canary the blog with Flagger on its Traefik SLIs

## Context

ADR 0044 defined availability and latency SLOs for the blog from Traefik's per-router RED metrics, with multi-burn-rate alerting. Those SLIs were built to become a delivery gate, not just a dashboard. The remaining gap was progressive delivery: rolling a new blog version gradually and rolling it back automatically when it breaches the same objectives that page a human.

The blog is served on the home cluster behind Traefik. The multi-cluster work (ADR 0047) puts a copy on EKS behind an ALB, but the ALB exposes no Prometheus metrics and Flagger has no native ALB analysis provider, whereas Traefik is a first-class Flagger provider. Progressive delivery therefore belongs on the home cluster, where it reuses the existing Traefik SLO metrics directly and is unaffected by the AWS teardown.

## Decision

Run Flagger on the home cluster with the Traefik provider and canary the blog. Flagger creates primary and canary Deployments and Services and a weighted Traefik service; the blog IngressRoute routes through that weighted service. Canary analysis steps traffic in increments and gates each step on two checks expressed as Flagger MetricTemplates against the existing Prometheus: request success rate at or above 99 percent, and p99 request duration at or below 500 milliseconds, matching the objectives in ADR 0044. Breaching the threshold for the configured number of intervals rolls the release back automatically.

The analysis reads per-service Traefik metrics scoped to the canary service, not the per-router metric the SLO rule uses. The router metric aggregates primary and canary traffic and cannot isolate the new version, so the SLO PrometheusRule from ADR 0044 keeps keying on the router for top-line monitoring while the canary keys on the service for promotion decisions. The IngressRoute keeps its name, so the router label is unchanged and the SLO rule continues to fire as before.

## Options considered

- Flagger on EKS against the ALB. Flagger has no ALB provider; this would require exporting CloudWatch metrics into Prometheus or a custom webhook, abandons the Traefik SLI reuse, and would be reverted with the rest of the AWS footprint. Rejected.
- Argo Rollouts. A capable alternative, but Flagger fits the existing Flux and Prometheus grain with no additional CRD-driven controller stack to learn. Rejected on fit, not merit.

## Consequences

The blog gains automated canary releases with rollback gated on the same numbers that define its reliability, closing the loop from ADR 0044. Flagger runs on the home cluster only and is independent of the AWS work, so it survives the teardown and remains a real capability; it is also removable on its own if the maintenance is not wanted.

Adopting the canary has two one-time costs: the first reconcile briefly returns 404 until Flagger creates the weighted service and primary, and the analysis needs real or generated traffic, since a metric query over an idle canary returns no data and fails the step.

## Update 2026-07-12

A blog deploy failed to promote and surfaced a deeper fault. Since the observability namespace gained default-deny NetworkPolicies on 2026-07-06, Prometheus ingress was admitted only from the traefik and monitoring namespaces. Flagger runs in the flagger namespace, so every canary metric query was refused and each analysis step failed regardless of Prometheus health, rolling releases back. The metric gate had been silently broken from that date. The gate was briefly removed to unblock deploys, then restored together with four refinements:

- A NetworkPolicy in the monitoring namespace admits the flagger namespace to Prometheus on port 9090, restoring the metric path that the earlier lockdown severed.
- A Flagger loadtester runs in the flagger namespace and drives traffic at the canary during analysis, so the success-rate and duration queries have real signal instead of returning no data over an idle canary, the cost recorded in Consequences above.
- Both MetricTemplates fall back to a passing value when a query returns no data, so a quiet canary no longer fails the step.
- A pre-rollout acceptance webhook asserts the canary serves its own content, adding a check that does not depend on Prometheus.

The failed-check threshold stays low, so a brief Prometheus blip is tolerated while a real objective breach still rolls back. A prolonged Prometheus outage fails safe, leaving the primary on the running version until the next attempt. The core decision, gating the blog canary on its Traefik SLIs, is unchanged; these are robustness refinements, so this ADR is amended rather than superseded.

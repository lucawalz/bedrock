---
status: accepted
date: 2026-06-21
---

# 0048. Canary the blog with Flagger on its Traefik SLIs

## Context

[0044](0044-slo-error-budget-burn-rate-alerting.md) defined availability and latency objectives for the blog from Traefik's per-router RED metrics, with multi-burn-rate alerting. Those indicators were built to become a delivery gate. The remaining gap was progressive delivery: rolling a new blog version gradually and rolling it back automatically when it breaches the same objectives that page a human. The multi-cluster work in [0047](0047-multi-cluster-cd-to-eks-peer.md) put a copy of the blog on EKS behind an ALB, but the ALB exposes no Prometheus metrics and Flagger has no native ALB analysis provider, whereas Traefik is a first-class Flagger provider. Progressive delivery therefore belongs on the home cluster, where it reuses the existing Traefik metrics directly and is unaffected by the AWS teardown.

## Decision

Run Flagger on the home cluster with the Traefik provider and canary the blog. Flagger creates primary and canary Deployments and Services and a weighted Traefik service, and the blog IngressRoute routes through that weighted service. Canary analysis steps traffic in increments and gates each step on two MetricTemplates against the existing Prometheus: request success rate must stay at or above 99 percent, and p99 request duration at or below 500 milliseconds. Breaching a threshold for the configured number of intervals rolls the release back automatically.

The analysis reads per-service Traefik metrics scoped to the canary service, not the per-router metric the SLO rule uses, because the router metric aggregates primary and canary traffic and cannot isolate the new version. The SLO PrometheusRule therefore keeps keying on the router for top-line monitoring while the canary keys on the service for promotion decisions, and the IngressRoute keeps its name so the router label is unchanged. The two sets of numbers are related but not identical: the promotion gate holds p99 duration to 500 milliseconds, while the latency objective in [0044](0044-slo-error-budget-burn-rate-alerting.md) is now measured against a 300 millisecond histogram boundary, so a release can promote inside a budget the objective is already spending.

## Options considered

- Flagger with the Traefik provider on the home cluster, chosen. It reuses the metrics the SLO work already produced, fits the existing Flux and Prometheus grain, and survives the AWS teardown.
- Flagger on EKS against the ALB. Rejected. Flagger has no ALB provider, so this would need CloudWatch metrics exported into Prometheus or a custom webhook, abandons the Traefik indicator reuse, and would be reverted with the rest of the AWS footprint.
- Argo Rollouts. A capable alternative, rejected on fit rather than merit: Flagger needs no additional controller stack beside the one already reconciling the cluster.

## Consequences

The blog gains automated canary releases with rollback gated on the numbers that define its reliability. Flagger runs on the home cluster only, so it survived the AWS teardown and remains a real capability, and it is removable on its own if the maintenance is not wanted.

Adopting the canary carried two costs that later had to be paid properly. The first reconcile briefly returns 404 until Flagger creates the weighted service and primary, and the analysis needs real traffic, since a metric query over an idle canary returns no data and fails the step. A deploy that failed to promote in July 2026 surfaced a sharper version of the second. Default-deny NetworkPolicies in the observability namespace had admitted Prometheus ingress only from the traefik and monitoring namespaces, and Flagger runs in its own, so every metric query was refused and each analysis step failed regardless of Prometheus health. The gate had been silently broken from the day the lockdown landed.

Four changes closed it and are what runs now. A NetworkPolicy in the monitoring namespace admits the flagger namespace to Prometheus on port 9090. A Flagger loadtester drives traffic at the canary during analysis so the queries have real signal. Both MetricTemplates fall back to a passing value when a query returns no data, so a quiet canary no longer fails the step. And a pre-rollout acceptance webhook asserts the canary serves its own content, which is a check that does not depend on Prometheus at all. The failed-check threshold stays low, so a brief Prometheus blip is tolerated while a real breach still rolls back, and a prolonged Prometheus outage fails safe by leaving the primary on the running version.

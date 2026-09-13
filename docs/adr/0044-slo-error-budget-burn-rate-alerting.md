---
status: accepted
date: 2026-06-20
---

# 0044. Define service SLOs with multi-burn-rate error-budget alerting

## Context

The cluster alerted on symptoms: a Flux reconciliation that stayed unready, a certificate close to expiry, a spike in error logs. None of those describe whether a workload is meeting the experience it promises, and none distinguish a brief blip from sustained degradation worth waking someone for. The observability stack from [0039](0039-observability-stack-loki-tempo-alloy.md) was already in place, with Alertmanager forwarding to the self-hosted ntfy from [0028](0028-self-hosted-ntfy-alerting.md). What was missing was a service-level objective: a target, a measurement of the distance to it, and an alert on the rate the remaining budget is spent rather than on an instantaneous threshold. The blog from [0019](0019-self-hosted-static-blog.md) is the first workload to get one, being user-facing and fronted by Traefik. A prerequisite blocked it: the chart from [0008](0008-traefik-ingress.md) ran with its Prometheus provider disabled, so there were no request counters or latency histograms to build an indicator from.

## Decision

Enable the Traefik Prometheus metrics provider on the chart's internal `metrics` entry point with per-router and per-service labels, and ship the chart's own metrics service and ServiceMonitor labelled `release: kube-prometheus-stack` rather than hand-writing one. Then define two blog SLOs over a rolling 30 days as recording rules and alert on them with the multi-window multi-burn-rate method from the Google SRE workbook.

Availability targets 99.9%, measured as the ratio of non-5xx to total requests from `traefik_router_requests_total`, with the 5xx numerator carrying `or vector(0)` so an idle router reports no errors rather than no data. Latency targets 99% of requests served inside the `le="0.3"` boundary of `traefik_router_request_duration_seconds_bucket`. Recording rules precompute each error ratio over every window the burn-rate alerts consume plus the 30d window the objective itself is measured over, and a `*_error_budget_remaining_ratio` rule expresses how much of the budget is left. A fast page fires at 14.4x over 1h and 5m, a medium page at 6x over 6h and 30m, and a slow ticket at 1x over 3d and 6h, the first two at `severity: critical` and the last at `severity: warning`, all routed to ntfy through the existing Alertmanager catch-all receiver. A Grafana dashboard provisioned through the kube-prometheus-stack sidecar shows budget remaining, burn rate, and the indicator over time.

Traefik generates the router label as `<entrypoint>-<namespace>-<ingressroute>-<hash>@kubernetescrd`, and the hash is not known until the route renders, so the rules match the `websecure-blog-blog-` prefix. Scraping Traefik also needed an ingress NetworkPolicy on port 9100 from the monitoring namespace, since the traefik namespace defaults to deny.

## Options considered

- Hand-written recording rules and multi-burn-rate alerts, chosen. The whole SLO is a single PrometheusRule that any reader can audit against the workbook, validated offline with `promtool check` and a `promtool test` unit fixture. It adds no controller and reuses the recording-rule and ServiceMonitor patterns already in the repo.
- Sloth, which generates the same rules from a compact SLO spec. It removes the per-window repetition, but the generated output is what runs, so it trades auditability for brevity and adds a generation step for a single workload.
- Pyrra, which manages SLOs as a CRD with its own controller and UI. The richest option and the heaviest: another operator, another CRD, and another component to keep healthy, for one SLO.

## Consequences

The blog has measurable, alertable objectives whose alerts fire on budget burn rate, so a brief blip stays quiet while sustained degradation pages quickly and slow erosion opens a ticket. The pattern is the template for every later SLO: add a ServiceMonitor if the target is not already scraped, then a PrometheusRule of recording rules and burn-rate alerts, then a dashboard ConfigMap.

The router-label matcher was the one piece that could not be verified offline. The prefix asserted from the IngressRoute naming convention was wrong, because Traefik v3 prefixes the entry point, and live scraping both corrected it and surfaced the missing metrics NetworkPolicy. The 30d windows mean the budget figures and the slow-burn ticket only become meaningful after thirty days of history and read as full until then. Per-router labels grow Traefik's metric cardinality with the number of routes, which is bounded by the handful of IngressRoutes it serves, and latency is measured at a single histogram bucket, so a tighter target would need custom buckets configured on the metrics provider.

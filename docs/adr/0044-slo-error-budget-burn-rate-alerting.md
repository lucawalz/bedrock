---
status: accepted
date: 2026-06-20
---

# 0044. Define service SLOs with multi-burn-rate error-budget alerting

## Context

The cluster alerts on symptoms: a Flux reconciliation that stays unready, a certificate close to expiry, a spike in error logs. None of these describe whether a workload is actually meeting the experience it promises to its users, and none distinguish a brief blip from sustained degradation worth waking someone for. The observability stack is already in place from [0039](0039-observability-stack-loki-tempo-alloy.md): kube-prometheus-stack scrapes the cluster, Alertmanager forwards to the self-hosted ntfy from [0028](0028-self-hosted-ntfy-alerting.md), and Grafana renders dashboards. What is missing is a service-level objective: a target, a measurement of how far the service is from it, and an alert that fires on the rate the remaining budget is being spent rather than on a raw instantaneous threshold.

The blog from [0019](0019-self-hosted-static-blog.md), served at the public apex under [0021](0021-public-blog-portfolio-domain.md), is the first workload to get one. It is user-facing, externally reachable, and fronted by Traefik, which makes it the natural place to prove the pattern before extending it.

A prerequisite blocked this: Traefik exposed no metrics. The chart from [0008](0008-traefik-ingress.md) ran with its Prometheus provider disabled, so there were no request counters or latency histograms to build a service-level indicator from.

## Decision

Enable the Traefik Prometheus metrics provider and ship it as a scrape target, then define two SLOs for the blog as recording rules and alert on them with the multi-window multi-burn-rate method from the Google SRE workbook.

Traefik gets its native Prometheus provider on the chart's existing internal `metrics` entry point, with per-router and per-service labels turned on so an indicator can name the blog. The chart's own dedicated metrics service and ServiceMonitor are enabled and labelled `release: kube-prometheus-stack` so the operator selects them, rather than hand-writing a ServiceMonitor as the cert-manager and Flux targets do.

The blog carries two SLOs over a rolling 30 days:

- Availability, target 99.9%. The indicator is the ratio of non-5xx to total requests, from `traefik_router_requests_total` filtered to the blog's router.
- Latency, target 99%. The indicator is the fraction of requests served in under 500ms, from `traefik_router_request_duration_seconds_bucket` at the `le="0.5"` boundary over the same router.

Recording rules precompute each error ratio over the seven windows the burn-rate alerts consume (5m, 30m, 1h, 2h, 6h, 1d, 3d) plus a 30d window, and a `*_error_budget_remaining_ratio` rule expresses how much of the 30d budget is left. Alerts then compare those ratios against burn-rate multiples of the budget, requiring two windows to agree before firing: a fast page at 14.4x over 1h and 5m, a medium page at 6x over 6h and 30m, and a slow ticket at 1x over 3d and 6h. The fast and medium tiers carry `severity: critical`, the slow tier `severity: warning`; both route to ntfy through the existing Alertmanager catch-all receiver. A Grafana dashboard, provisioned through the kube-prometheus-stack sidecar by a labelled ConfigMap, shows budget remaining, burn rate, and the indicator over time.

The blog's Traefik router label is generated as `<entrypoint>-<namespace>-<ingressroute>-<hash>@kubernetescrd`, where the hash is not known until Traefik renders the route. Live metrics confirm the blog's serving route as `websecure-blog-blog-<hash>@kubernetescrd`, so the rules match it by the `websecure-blog-blog-` prefix. Scraping Traefik also required an ingress NetworkPolicy on port 9100 from the monitoring namespace, since the traefik namespace defaults to deny.

## Options considered

- Hand-written recording rules and multi-burn-rate alerts, chosen. The whole SLO is a single PrometheusRule that any reader can audit against the workbook, validated offline with `promtool check` and a `promtool test` unit fixture that asserts a burn-rate alert fires at its threshold and the budget rule computes. It adds no controller and no new failure surface, and it reuses the recording-rule and ServiceMonitor patterns already in the repo.
- Sloth, which generates the same rules from a compact SLO spec. It removes the repetition of eight windows per indicator, but the generated output is what runs, so it trades auditability for brevity and adds a generation step to the pipeline for a single workload. Worth revisiting only once several services carry SLOs.
- Pyrra, which manages SLOs as a CRD with its own controller and UI. It is the richest option and the heaviest: another operator, another CRD, and another component to keep healthy, for one SLO. The cost is not justified at this scale.

## Consequences

Traefik now exposes a metrics endpoint and the blog has measurable, alertable objectives whose alerts fire on budget burn rate, so a brief blip stays quiet while sustained degradation pages quickly and slow erosion opens a ticket. The pattern is the template for every later SLO: add a ServiceMonitor if the target is not already scraped, then a PrometheusRule of recording rules and burn-rate alerts, then a dashboard ConfigMap.

The router-label matcher was the one piece that could not be verified offline: the initial `blog-blog-` prefix asserted from the IngressRoute naming convention was wrong, because Traefik v3 prefixes the entry point. Live scraping corrected it to `websecure-blog-blog-` and surfaced the missing metrics NetworkPolicy; both are now fixed and confirmed against live series. The 30d windows mean the budget-remaining figures and the slow-burn ticket alert only become meaningful after the series has thirty days of history, and read as full until then.

Enabling per-router and per-service labels grows Traefik's metric cardinality with the number of routes, which is small on this cluster and bounded by the handful of IngressRoutes it serves. Latency is measured at a single 500ms histogram bucket, so the SLO is only as precise as the chart's default bucket boundaries; a tighter latency target would need custom buckets configured on the metrics provider.

---
status: accepted
date: 2026-11-07
---

# 0015. Observe with Prometheus, Loki and Tempo

## Context

The cluster runs unattended most of the time, and the owner should hear about a problem before a user does, without being paged for conditions that need no action. A monitoring stack that runs inside the cluster cannot report its own death.

## Decision

- kube-prometheus-stack provides Prometheus, Alertmanager and Grafana. Loki stores logs and Tempo stores traces, and Grafana Alloy collects both. Components without a chart-provided monitor get a ServiceMonitor in `kubernetes/infrastructure/controllers/observability/alert-rules`.
- Rules the charts do not ship live in one PrometheusRule with promtool unit tests (`scripts/check-alert-rules.sh`). `scripts/check-alert-selectors.sh` checks against the live cluster that every series a rule selects exists, so a rule cannot go silent because a metric was renamed or dropped.
- Alertmanager routes by severity. Critical alerts reach ntfy at urgent priority, warnings at normal priority, and info alerts go to the null receiver; an alert that needs no action is info, as `LonghornVolumeOverDeclared` is. Flux error events reach the same ntfy instance.
- The Alertmanager Watchdog pings a deadman receiver on the router every five minutes. The router marks the estate stale after four missed pings, which covers the case where the cluster cannot alert at all.
- The router's bar panel shows the Grafana wall dashboard through a public dashboard share. A Job recreates the share from git with a fixed token kept in `bedrock-secrets`, so the panel survives a rebuild of the Grafana database, and it shows the deadman status beside it.
- The blog has SLOs with multi-window burn-rate alerts, and Flagger releases it as a canary judged on its Traefik metrics.

## Consequences

- One ntfy topic carries every actionable signal, and info-level noise stays visible in Grafana without paging.
- A dead cluster is noticed on the panel within about 25 minutes, even with Alertmanager gone.
- The live selector check cannot run in CI and is run by hand after rule changes and rebuilds.

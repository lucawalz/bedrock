---
status: accepted
date: 2026-11-07
---

# 0015. Observe with Prometheus, Loki and Tempo

## Context

The cluster runs unattended most of the time, and the owner should hear about a problem before a user does, without being paged for conditions that need no action. A monitoring stack that runs inside the cluster cannot report its own death.

## Decision

- kube-prometheus-stack provides Prometheus, Alertmanager and Grafana. Loki stores logs and Tempo stores traces, and Grafana Alloy collects both. Components without a chart-provided monitor get a ServiceMonitor in `kubernetes/infrastructure/controllers/observability/alert-rules`.
- Rules the charts do not ship live in two PrometheusRules in `alert-rules`, `prometheusrule.yaml` and `slo-blog.yaml`, with promtool unit tests (`scripts/check-alert-rules.sh`). `scripts/check-alert-selectors.sh` checks against the live cluster that every series a rule selects exists, so a rule cannot go silent because a metric was renamed or dropped.
- Alertmanager routes by severity. Critical alerts reach ntfy at urgent priority, warnings at normal priority, and info alerts go to the null receiver; an alert that needs no action is info, as `LonghornVolumeOverDeclared` is. Flux error events reach the same ntfy instance.
- ntfy denies anonymous access. Alertmanager, Grafana and the Flux Provider each publish with their own write-only token, and the owner's phone reads both topics as the read-only `phone` user. ntfy provisions its users and tokens from `bedrock-secrets` and its access list from the HelmRelease at every start, so the auth database lives on an `emptyDir`.
- The Alertmanager Watchdog pings a deadman receiver on the router every five minutes. The router marks the estate stale after four missed pings, which covers the case where the cluster cannot alert at all.
- The router's bar panel shows the Grafana wall dashboard through a public dashboard share. A Job recreates the share from git with a fixed token kept in `bedrock-secrets`, so the panel survives a rebuild of the Grafana database, and it shows the deadman status beside it.
- The blog has SLOs with multi-window burn-rate alerts, and Flagger releases it as a canary judged on its Traefik metrics.
- The API server on control-plane-1 writes an audit log to `/var/log/kubernetes/audit.log`, rotated by the API server. The policy records Secrets, exec, attach and port-forward at Metadata level for every verb and every other write at Metadata level, and drops reads, leases, events and access reviews. No rule records a request or response body. Alloy reads the file through its existing read-only `/var/log` mount and ships it to Loki as `job="kubernetes-audit"`, stamped with each event's `stageTimestamp` and paced to 100 lines a second.
- etcd metrics are not scraped. K3s serves them on loopback only, and the alternative, a client certificate for the etcd client port, would put a credential for the whole datastore into the monitoring stack.

## Consequences

- One ntfy instance carries every actionable signal, on two topics: `alerts` for Alertmanager and `flux` for Flux events. Info-level noise stays visible in Grafana without paging.
- The ntfy host has no forward-auth: ntfy's own deny-all users and tokens are the gate, so the native app on the LAN or tailnet signs in as `phone`. The host stays internal, off the tunnel.
- ntfy forwards a poll request for every message to `https://ntfy.sh`, so the iOS app is woken through Apple push instead of polling. The request carries only the message ID and a SHA-256 of the topic URL, never the content, and leaves through the namespace's existing public egress on 443.
- Grafana reads its token only when it provisions at startup, so a rotated Grafana token needs a Grafana restart.
- A dead cluster is noticed on the panel within about 25 minutes, even with Alertmanager gone.
- The live selector check cannot run in CI and is run by hand after rule changes and rebuilds.
- etcd disk latency is not watched. `EtcdRequestsSlow` reads the API server's client-side etcd latency instead, which includes but cannot isolate slow WAL fsyncs.
- An audit policy change takes effect only through the K3s restart that a rebuild of control-plane-1 triggers, which briefly takes down the only API server.

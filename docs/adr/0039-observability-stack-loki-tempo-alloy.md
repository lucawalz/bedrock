---
status: accepted
date: 2026-06-19
---

# 0039. Observability stack with Loki, Tempo, and Grafana Alloy

> Update 2026-06-21: the standalone Alertmanager is retained, not removed. The kube-prometheus-stack default alert set, more than 150 Prometheus-evaluated rules covering nodes, storage, and workloads, delivers only through Alertmanager, and Grafana's unified alerting evaluates its own rules rather than these, so removing Alertmanager would silence them. Grafana alerting still runs the operator-authored log-error rule to ntfy and coexists with Alertmanager.

## Context

The home cluster has had metrics and alerting since [0018](0018-internal-dashboard-and-router-metrics.md): kube-prometheus-stack runs Prometheus, a single Alertmanager that forwards to ntfy, and Grafana, with node-exporter, kube-state-metrics, and a static scrape of the Pi router. What it has never had is logs or traces. Pod logs lived only in the kubelet and were lost on eviction, and there was no trace backend at all. Grafana showed metrics and nothing else, so any investigation that needed a log line meant a `kubectl logs` against a guess at the right pod.

The goal is a single Grafana that answers metrics, logs, and traces together, collected by one agent, with everything stored on the cluster's own disks rather than an external object store, and with alerting folded into Grafana so the stack carries one fewer moving part.

## Decision

Keep Prometheus as the metrics store and add the rest of the Grafana stack around it: Loki for logs, Tempo for traces, and Grafana Alloy as the collector, all in the existing `monitoring` namespace and reconciled by `cluster-infrastructure`.

Alloy runs as a DaemonSet and does two things only: it tails every pod's container logs and writes them to Loki, and it accepts OpenTelemetry traces over OTLP and forwards them to Tempo. Metrics are left entirely to Prometheus, which keeps scraping through the existing ServiceMonitors, and Alloy never touches them. Loki and Tempo each run as a single binary with the filesystem backend on a Longhorn volume, so log and trace data stays replicated across the cluster's own nodes with no S3 or MinIO dependency. Loki keeps fourteen days, Tempo seven. Each component exposes its own metrics back to Prometheus through a ServiceMonitor.

Grafana gains Loki and Tempo as datasources alongside Prometheus, wired for correlation so a trace identifier in a log jumps to the trace and a span links back to its logs. Alerting moves into Grafana's built-in engine: a handful of operator-authored rules evaluate against Prometheus, and a webhook contact point delivers to the same ntfy topic the cluster already uses. With Grafana alerting proven, the standalone Alertmanager and its ingress are removed and the orphaned `PrometheusNotConnectedToAlertmanagers` rule is disabled.

The migration is staged: the collector and stores go in first as purely additive components, then Grafana is pointed at them, then alerting is moved, and Alertmanager is removed last, only once notifications are confirmed arriving through Grafana.

## Options considered

- Loki and Tempo behind Alloy with Prometheus retained, chosen. It adds logs and traces and unifies the view in Grafana while leaving the working metrics path untouched, and single-binary filesystem deployments keep the footprint small.
- Mimir as the metrics store in place of Prometheus, rejected. Mimir is a distributed, multi-component system built for scale and long retention; on three nodes it is operational weight with no benefit over a single Prometheus, which speaks the same query language and feeds the same dashboards.
- Object storage for Loki and Tempo, rejected. An external S3 bucket or an in-cluster MinIO would give the tools their native backend, but the cluster already has replicated Longhorn volumes and the explicit preference was to keep observability data on the cluster's own disks with nothing new to depend on.
- Promtail for log collection, rejected. It reached end of life in early 2026 and Alloy is its supported successor, so a new deployment starts on Alloy and gains the trace pipeline in the same agent.
- Keeping the standalone Alertmanager, rejected. Grafana's unified alerting covers a single operator's needs, and routing the same ntfy notifications from Grafana removes a component and keeps rules and dashboards in one console.

## Consequences

Grafana becomes the single place to read the cluster: metrics from Prometheus, logs from Loki, traces from Tempo, and one alert path to ntfy. An investigation can move from a spiking metric to the logs around it to the trace that caused it without leaving the console. The added cost is modest, roughly a quarter of a core, three quarters of a gigabyte of memory, and thirty gigabytes of Longhorn, partly offset by removing Alertmanager.

The trace backend is set up before anything emits traces, so Tempo sits empty until an application is instrumented to send OTLP to Alloy, and the pipeline is ready when that day comes. Apps in default-deny namespaces will each need an egress policy to reach Alloy on the OTLP ports, added per app when they start sending traces rather than up front.

A few sharp edges are worth recording. The single-binary `grafana/tempo` chart is deprecated in favor of `tempo-distributed`; it still runs the current Tempo and is the right size for a homelab, and the distributed chart is the migration path if traces ever outgrow one node. Loki and Tempo run a single replica on the filesystem backend, so they are not highly available and a node reboot can lose data still in flight, which is acceptable here. Grafana does not always restart when only its provisioned datasources or alert rules change, so those edits are followed by a manual rollout. And ntfy receives a different payload shape from Grafana than it did from Alertmanager, so the notification template is tuned once after the first delivery lands.

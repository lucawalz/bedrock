---
status: accepted
date: 2026-06-19
---

# 0039. Observability stack with Loki, Tempo, and Grafana Alloy

## Context

The home cluster has had metrics and alerting since [0018](0018-internal-dashboard-and-router-metrics.md): kube-prometheus-stack runs Prometheus, a single Alertmanager that forwards to ntfy, and Grafana, with node-exporter, kube-state-metrics, and a static scrape of the Pi router. What it had never had is logs or traces. Pod logs lived only in the kubelet and were lost on eviction, there was no trace backend at all, and any investigation that needed a log line meant a `kubectl logs` against a guess at the right pod. The goal is a single Grafana that answers metrics, logs, and traces together, collected by one agent, with everything stored on the cluster's own disks rather than an external object store.

## Decision

Keep Prometheus as the metrics store and add the rest of the Grafana stack around it: Loki for logs, Tempo for traces, and Grafana Alloy as the collector, all in the existing `monitoring` namespace, with Prometheus, Loki, and Tempo reconciled by `cluster-observability` and Alloy by `cluster-alloy` under the split established in [0058](0058-split-cluster-infrastructure-kustomizations.md). Alloy runs as a DaemonSet and does two things only: it tails every pod's container logs and writes them to Loki, and it accepts OpenTelemetry traces over OTLP and forwards them to Tempo. Metrics are left entirely to Prometheus, which keeps scraping through the existing ServiceMonitors. Loki and Tempo each run as a single binary with the filesystem backend on a Longhorn volume, so log and trace data stays replicated across the cluster's own nodes with no object-store dependency, with Loki keeping fourteen days and Tempo seven, and each component exposing its own metrics back to Prometheus. Grafana gains Loki and Tempo as datasources alongside Prometheus, wired for correlation so a trace identifier in a log jumps to the trace and a span links back to its logs. Grafana's built-in engine runs a handful of operator-authored rules that evaluate against Prometheus and deliver to the same ntfy topic, and the standalone Alertmanager is retained alongside it, because Grafana's unified alerting evaluates only its own rules and the kube-prometheus-stack default rule set delivers through Alertmanager alone.

## Options considered

- Loki and Tempo behind Alloy with Prometheus retained, chosen. It adds logs and traces and unifies the view in Grafana while leaving the working metrics path untouched, and single-binary filesystem deployments keep the footprint small.
- Mimir as the metrics store in place of Prometheus, rejected. Mimir is a distributed, multi-component system built for scale and long retention; on three nodes it is operational weight with no benefit over a single Prometheus, which speaks the same query language and feeds the same dashboards.
- Object storage for Loki and Tempo, rejected. An external bucket or an in-cluster object store would give the tools their native backend, but the cluster already has replicated Longhorn volumes and the explicit preference was to keep observability data on its own disks.
- Promtail for log collection, rejected. It reached end of life in early 2026 and Alloy is its supported successor, so a new deployment starts on Alloy and gains the trace pipeline in the same agent.
- Removing the standalone Alertmanager once Grafana alerting proved out, rejected on trial. Dropping it would silence the kube-prometheus-stack default alerts that deliver only through it, so the two coexist.

## Consequences

Grafana becomes the single place to read the cluster, and an investigation can move from a spiking metric to the logs around it to the trace that caused it without leaving the console, for roughly a quarter of a core, three quarters of a gigabyte of memory, and thirty gigabytes of Longhorn. The trace backend is set up before anything emits traces, so Tempo sits empty until an application is instrumented, and apps in default-deny namespaces each need an egress policy to reach Alloy on the OTLP ports. A few sharp edges are worth recording. The single-binary Tempo chart is deprecated in favour of the distributed one, which is the migration path if traces ever outgrow one node. Loki and Tempo run a single replica on the filesystem backend, so they are not highly available and a node reboot can lose data still in flight, which is acceptable here. Grafana does not always restart when only its provisioned datasources or alert rules change, so those edits are followed by a manual rollout. And ntfy receives a different payload shape from Grafana than it does from Alertmanager, so the notification template is tuned once after the first delivery lands.

---
status: accepted
date: 2026-06-14
---

# 0020. Roll workloads on config and secret change with Reloader

## Context

Kubernetes does not restart a workload when a ConfigMap or Secret it mounts changes. A Deployment keeps its running Pods until its own template changes, so an edit to a mounted config is reconciled into the object but never reaches the process. The cloudflared tunnel exposed this directly: adding a hostname to its `cloudflared-config` ConfigMap reconciled cleanly, yet the running tunnel kept serving the old routing table until someone ran `kubectl rollout restart` by hand. A manual restart after every config edit is easy to forget and turns a declarative change into a two-step operation, which is exactly the kind of drift GitOps is meant to remove. The bjw-s app-template chart that backs cloudflared does compute a content checksum, but only for configMaps and secrets it owns, and the cloudflared config and tunnel credentials are managed outside the chart and mounted by name, so they never enter it. Homepage, then a plain Deployment mounting an externally managed ConfigMap, had no checksum mechanism at all.

## Decision

[Stakater Reloader](https://github.com/stakater/Reloader) runs as a cluster-wide infrastructure controller. It watches ConfigMaps and Secrets and triggers a rolling restart of the workloads that consume them by writing a changing annotation into the Pod template. That is the same effect a manual `kubectl rollout restart` produces, applied automatically the moment the source changes.

It is deployed from the `stakater/reloader` chart in its own `reloader` namespace, reconciled by the `cluster-security` Kustomization alongside the other security controllers. Reloader runs with `watchGlobally` left on so a single controller covers the whole cluster, but rollouts are opt-in per workload: only workloads carrying `reloader.stakater.com/auto: "true"` on their Deployment metadata are rolled. Workloads that use app-template set it through the `controllers.<name>.annotations` key, which lands on the Deployment object itself where Reloader reads it.

## Options considered

- Reloader as a cluster controller with per-workload opt-in, chosen. One controller covers every namespace, it handles externally managed configMaps and secrets that a chart's own checksum cannot see, and the opt-in annotation keeps the blast radius to workloads that have been enrolled. It also covers SOPS secret rotation without any per-workload machinery.
- The chart-native checksum in app-template. It already ships and adds no new controller, but it only hashes chart-owned configMaps and secrets, so it does not solve the case that prompted this.
- Carrying on with manual `kubectl rollout restart`. No new component to run, but it is a manual step that is easy to forget, it breaks the declarative model, and it leaves a window where the reconciled config and the running process disagree.

## Consequences

A change to a watched ConfigMap or Secret rolls the annotated workloads on its own, so editing the cloudflared routing table is a single committed change that reaches the running Pods. The same path covers secret rotation: when a SOPS-managed Secret is re-encrypted and reconciled, the workloads that mount it and opt in roll to pick it up. The cost is one more controller to run and keep current, and a discipline point: a workload that needs config-driven rollouts must carry the annotation, because the opt-in model does nothing for workloads that have not been enrolled. Cluster-wide automatic restarts would roll workloads on unrelated config edits and widen the blast radius well beyond what is wanted.

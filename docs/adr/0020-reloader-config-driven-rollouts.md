---
status: accepted
date: 2026-06-14
---

# 0020. Roll workloads on config and secret change with Reloader

## Context

Kubernetes does not restart a workload when a ConfigMap or Secret it mounts changes. A Deployment keeps its running Pods until its own template changes, so an edit to a mounted config is reconciled into the object but never reaches the process. The cloudflared tunnel exposed this directly: adding a hostname to its `cloudflared-config` ConfigMap reconciled cleanly, yet the running tunnel kept serving the old routing table until someone ran `kubectl rollout restart` by hand. A manual restart after every config edit is easy to forget and turns a declarative change into a two-step operation, which is exactly the kind of drift GitOps is meant to remove.

The bjw-s app-template chart that backs cloudflared does compute a content checksum, but only for configMaps and secrets it owns under its own `.Values.configMaps` and `.Values.secrets`. Its pod annotations helper hashes those values and writes `checksum/configMaps` and `checksum/secrets` into the Pod template, which rolls the workload when their content moves. The cloudflared config and the tunnel credentials are managed outside the chart and mounted by name through `persistence`, so they never enter that checksum, and the chart-native mechanism cannot see them. Homepage is a plain Deployment that mounts an externally managed ConfigMap and has no checksum mechanism at all.

## Decision

[Stakater Reloader](https://github.com/stakater/Reloader) runs as a cluster-wide infrastructure controller. It watches ConfigMaps and Secrets and triggers a rolling restart of the workloads that consume them by writing a changing annotation into the Pod template, which is the same effect a manual `kubectl rollout restart` produces, applied automatically the moment the source changes.

It is deployed from the `stakater/reloader` chart, pinned to chart version `2.2.12`, in its own `reloader` namespace, registered in the infrastructure kustomization alongside the other cluster controllers. Reloader is run with `watchGlobally` left on so a single controller covers the whole cluster, but rollouts are opt-in per workload rather than automatic for everything: only workloads carrying `reloader.stakater.com/auto: "true"` on their Deployment metadata are rolled. cloudflared and homepage carry that annotation today. cloudflared sets it through the app-template `controllers.cloudflared.annotations` key, which lands on the Deployment object itself where Reloader reads it; homepage sets it directly in its Deployment `metadata.annotations`.

## Options considered

- Reloader as a cluster controller with per-workload opt-in, chosen. One controller covers every namespace, it handles externally managed configMaps and secrets that a chart's own checksum cannot see, and the opt-in annotation keeps the blast radius to workloads that have been deliberately enrolled. It also covers future SOPS secret rotation without any per-workload machinery.
- The chart-native checksum in app-template. It already ships and adds no new controller, but it only hashes chart-owned configMaps and secrets. The cloudflared config and credentials are managed outside the chart and mounted by name, so they fall outside the checksum, and homepage has no such mechanism at all. It does not solve the case that prompted this.
- Carrying on with manual `kubectl rollout restart`. No new component to run, but it is a manual step that is easy to forget, it breaks the declarative model, and it leaves a window where the reconciled config and the running process disagree.

## Consequences

A change to a watched ConfigMap or Secret now rolls the annotated workloads on its own, so editing the cloudflared routing table or a homepage config file is a single committed change that reaches the running Pods without a manual restart. The same path covers secret rotation: when a SOPS-managed Secret is re-encrypted and reconciled, the workloads that mount it and opt in will roll to pick it up, which removes a manual step from future credential rotation.

The cost is one more controller to run and keep current, and a discipline point: a workload that needs config-driven rollouts must carry the annotation, because the opt-in model does nothing for workloads that have not been enrolled. That trade is deliberate, since cluster-wide automatic restarts would roll workloads on unrelated config edits and widen the blast radius well beyond what is wanted.

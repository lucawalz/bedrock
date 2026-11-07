---
status: superseded by 0033
date: 2026-06-17
---

# 0030. Accept an externally managed control plane for the burst cluster

## Context

The `burst` Cluster had no `spec.controlPlaneRef`. Its k3s control plane was not provisioned by Cluster API; it ran on the home nodes and was reached through the `controlPlaneEndpoint` set on the HetznerCluster, and CAPH provisioned only worker machines and joined them to that pre-existing control plane. CAPI still expects a control-plane object for every Cluster, so horizon nudged the cluster controller past initialization by setting `status.initialization.controlPlaneInitialized=true` through a status-subresource patch. That patch let infrastructure provisioning proceed but did not satisfy the controller's own readiness accounting. Under the CAPI v1beta2 contract the cluster controller computed `ControlPlaneInitialized=False` and `WorkerMachinesReady=Unknown` regardless of the nudge, because it waits for a control-plane machine carrying a node reference and no such machine exists for an externally managed control plane. The worker MachineDeployment therefore reported `readyReplicas: 0` by design even when its machines were healthy and genuinely serving workloads.

## Decision

Accept the externally managed control plane and the readiness accounting that follows from it. horizon reads pool readiness from node Ready state rather than from MachineDeployment `readyReplicas`, so a `readyReplicas` of 0 against Ready nodes does not block or mislead pool operations. The status nudge stays as the minimal signal that lets infrastructure provisioning proceed without introducing a control-plane object that CAPI would then try to manage. The deeper structural fix is a real `controlPlaneRef` pointing at an externally managed control-plane object, deferred at the time to a CAPH and CAPI upgrade where the supporting types were expected to settle. [0033](0033-adopt-external-controlplane-object.md) corrects that deferral: the release it waited on does not exist, and the annotation this record reached for is not the switch it was taken to be.

## Options considered

- Keep the status-field nudge and read pool readiness from node Ready state, chosen. It is the smallest change that keeps provisioning working, and it confines the workaround to how horizon interprets readiness rather than to new cluster objects.
- Add a real or stub externally managed control-plane object immediately. It would make CAPI's readiness accounting correct, but its behaviour was believed to be gated on an upcoming provider release, so adopting it early looked like churn against types that were still changing.
- Leave the behaviour undocumented and let each operator rediscover why `readyReplicas` stays 0, rejected. The mismatch between a 0 `readyReplicas` and a Ready node is exactly the kind of surprise an ADR exists to record.

## Consequences

The burst cluster provisioned and ran workers against a control plane CAPI did not manage, at the cost of a permanent `ControlPlaneInitialized=False` and `WorkerMachinesReady=Unknown` on the Cluster and a `readyReplicas` of 0 on the worker MachineDeployment. Anyone reading those fields directly saw a cluster that looked unready while it was serving, so node Ready state was the authoritative readiness signal, which is how horizon already read it. The nudge had to keep being applied, since dropping it stalled infrastructure provisioning again. [0033](0033-adopt-external-controlplane-object.md) supersedes the workaround with a control-plane object that exposes the initialization contract, and restores CAPI's native readiness accounting.

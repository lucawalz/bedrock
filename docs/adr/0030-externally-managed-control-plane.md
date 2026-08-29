---
status: superseded by 0033
date: 2026-06-17
---

# 0030. Accept an externally managed control plane for the burst cluster

> Superseded by [0033](0033-adopt-external-controlplane-object.md), which provides a control-plane object and controller to retire the status nudge.

## Context

The `burst` Cluster has no `spec.controlPlaneRef`. Its k3s control plane is not provisioned by Cluster API; it runs on the home nodes and is reached through the `controlPlaneEndpoint` of `10.20.0.10:6443` set on the HetznerCluster. CAPH provisions only worker machines for this cluster and joins them to that pre-existing control plane.

CAPI still expects a control-plane object for every Cluster. To keep the cluster controller moving past initialization, horizon nudges it by setting `status.initialization.controlPlaneInitialized=true` through a status-subresource patch. That patch lets infrastructure provisioning proceed, but it does not satisfy the controller's own readiness accounting.

Under CAPI v1beta2 the cluster controller computes `ControlPlaneInitialized=False` and `WorkerMachinesReady=Unknown` regardless of the status nudge. The controller waits for a control-plane machine carrying a `status.nodeRef`, and no such machine exists for an externally managed control plane, so it never observes the signal it expects. As a result the worker MachineDeployment reports `readyReplicas: 0` by design even when its machines are healthy. The worker nodes are nonetheless genuinely k3s-Ready, join the control plane, and run workloads.

## Decision

Accept the externally managed control plane and the readiness accounting that follows from it. horizon reads pool readiness from node Ready state rather than from MachineDeployment `readyReplicas`, so a `readyReplicas` of 0 against Ready nodes does not block or mislead pool operations.

The status nudge stays. It is the minimal signal that lets infrastructure provisioning proceed without introducing a control-plane object that CAPI would then try to manage.

The deeper structural fix is a real `controlPlaneRef` pointing at an externally managed control-plane object that uses the `cluster.x-k8s.io/managed-by` pattern, which tells CAPI to skip reconciling the control plane while still satisfying its readiness model. That work is deferred to the planned CAPH v1.2 and CAPI upgrade, where the supporting types and behaviour are expected to settle.

## Options considered

- Keep the status-field nudge and read pool readiness from node Ready state, chosen. It is the smallest change that keeps provisioning working today, and it confines the workaround to how horizon interprets readiness rather than to new cluster objects.
- Add a real or stub externally managed control-plane object now, using the `cluster.x-k8s.io/managed-by` pattern. It would make CAPI's readiness accounting correct, but it adds moving parts whose behaviour is gated on the CAPH v1.2 and CAPI upgrade, so adopting it early risks churn against types that are still changing.
- Leave the behaviour undocumented and let each operator rediscover why `readyReplicas` stays 0, rejected. The mismatch between a 0 `readyReplicas` and a Ready node is exactly the kind of surprise an ADR exists to record.

## Consequences

The burst cluster provisions and runs workers against a control plane CAPI does not manage, at the cost of a permanent `ControlPlaneInitialized=False` and `WorkerMachinesReady=Unknown` on the Cluster and a `readyReplicas` of 0 on the worker MachineDeployment. Anyone reading those fields directly will see a cluster that looks unready while it is in fact serving, so node Ready state is the authoritative readiness signal until the structural fix lands. horizon already reads readiness that way, so pool operations are unaffected. The status nudge must continue to be applied; if it is dropped, infrastructure provisioning stalls again. When the CAPH v1.2 and CAPI upgrade arrives, the `controlPlaneRef` with the `managed-by` pattern supersedes this workaround and restores CAPI's native readiness accounting.

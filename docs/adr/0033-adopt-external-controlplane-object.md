---
status: superseded by 0041
date: 2026-06-17
---

# 0033. Adopt a custom ExternalControlPlane object for the burst cluster

## Context

[0030](0030-externally-managed-control-plane.md) accepted a status nudge as the way to move the `burst` Cluster past initialization. horizon patches `status.initialization.controlPlaneInitialized=true` on the Cluster so infrastructure provisioning proceeds against the externally run k3s control plane at `10.20.0.10:6443`. The nudge is imperative, runs outside GitOps, and the core CAPI cluster controller still computes `ControlPlaneInitialized=False` because no control-plane object exposes the contract it reads.

Three claims in 0030 were wrong and are corrected here:

- 0030 reached for the `cluster.x-k8s.io/managed-by` annotation as the switch that tells the core cluster controller to skip control-plane reconciliation. It is not. `managed-by` is an InfraCluster back-off signal that tells an infrastructure provider an external system owns that object; it does not change how the core cluster controller accounts for control-plane initialization.
- 0030 deferred the structural fix to "the planned CAPH v1.2 and CAPI upgrade". There is no CAPH v1.2 release. The latest is v1.1.6, which is the version this cluster runs (`providers/infrastructure-hetzner.yaml`). The v1beta1 InfraMachine removal that motivated the wait is tentatively scheduled for around April 2027, so the deferral rested on a release that does not exist.
- CAPH already supports an externally set `controlPlaneEndpoint` (syself/cluster-api-provider-hetzner#845), so the endpoint side was never the gap. The gap is purely the core CAPI `ControlPlaneInitialized` accounting, which requires a control-plane object that exposes the initialization contract.

## Decision

Provide a custom `ExternalControlPlane` control-plane object and a controller that reconciles it. The CRD `externalcontrolplanes.controlplane.horizon.dev` (GVK `controlplane.horizon.dev/v1alpha1`, namespaced) carries the CAPI contract labels `cluster.x-k8s.io/v1beta1: v1alpha1` and `cluster.x-k8s.io/v1beta2: v1alpha1`. The controller reads `spec.controlPlaneEndpoint` and `spec.version` and sets the status the core cluster controller needs: `controlPlaneInitialized`, `externalManagedControlPlane`, `initialized`, `ready`, and `version`. Once a `controlPlaneRef` on the burst Cluster points at this object and the controller populates its status, the core controller observes a genuinely initialized externally managed control plane, and horizon's imperative nudge can retire.

The rollout is staged to avoid a regression. The cluster controller reads the referenced control-plane object's status directly; a `controlPlaneRef` added before the controller is running and populating that status would read an empty status and flip `controlPlaneInitialized` back to false, undoing the nudge it is meant to replace. So the steps are ordered and each later step is gated on verifying the previous one:

1. Deploy the controller, CRD, RBAC, and the burst `ExternalControlPlane` object (this change). These are inert until something references the object, so they are safe to land first while the nudge still runs.
2. After the `ghcr.io/lucawalz/horizon-controller` image is published and the controller is confirmed populating the burst object's status (`controlPlaneInitialized=true`, `externalManagedControlPlane=true`, `ready=true`), add `spec.controlPlaneRef` to the burst Cluster pointing at the object.
3. After the core cluster controller is confirmed reporting `ControlPlaneInitialized=True` from the object rather than the nudge, retire horizon's status nudge.

The controller runs as a single replica in `caph-system` alongside the CAPI plane and the burst objects it serves, with leader election disabled. A second ClusterRole labelled `cluster.x-k8s.io/aggregate-to-manager: "true"` grants the Rancher Turtles or CAPI manager's aggregated role both read and write access to the CR. The manager does not only read the status it bubbles; it also patches the object's metadata to set the owner reference and `cluster.x-k8s.io/cluster-name` label, so read-only access leaves the core cluster controller failing with a forbidden error and the readiness conditions stuck on InternalError. Status access stays read-only, since only the horizon controller writes status.

## Options considered

- Custom `ExternalControlPlane` CRD plus controller, staged behind verification, chosen. It exposes the exact contract the core controller reads, lands as ordinary GitOps, and replaces an imperative out-of-band patch with a reconciled object.
- Keep the status nudge indefinitely, rejected. It works but stays imperative, runs outside GitOps, and leaves `ControlPlaneInitialized=False` permanently, so the readiness fields keep misleading anyone who reads them.
- Wait for an upstream externally managed control-plane type, rejected. The deferral in 0030 pointed at a CAPH release that does not exist, and no settled upstream type fills the core CAPI gap on the running versions, so waiting is open-ended.

## Consequences

The burst Cluster gains a real control-plane object whose status the core cluster controller can read, which is the path to correct CAPI readiness accounting without the imperative nudge. Until the image is published the controller pod sits in ImagePullBackOff, which is harmless because nothing references the object yet and the nudge still carries initialization. The `controlPlaneRef` cutover and the nudge retirement are deliberately not part of this change; performing either before the controller is verified to populate the object's status would regress `controlPlaneInitialized` to false and stall provisioning. This supersedes [0030](0030-externally-managed-control-plane.md): the nudge is now a transitional mechanism with a defined exit rather than a permanent workaround.

The staged rollout has since completed and was verified live: the controller populates the burst object's status, the `controlPlaneRef` points at it, and the burst Cluster reports `Available=True` with `ControlPlaneInitialized=True` and `ControlPlaneAvailable=True` sourced from the object, so the nudge has been retired. One bootstrap caveat surfaced. The `cluster-capi` Flux Kustomization runs with `wait: true`, so it health-gates on the very Cluster this object initializes, and the first application deadlocks: the RBAC that lets the manager patch the object cannot land while the Kustomization is blocked waiting for the Cluster to become ready. Breaking the deadlock once by applying the committed RBAC directly lets the cluster controller proceed, after which Flux converges onto the same content with no drift.

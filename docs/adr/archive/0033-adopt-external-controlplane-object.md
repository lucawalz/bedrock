---
status: superseded by 0041
date: 2026-06-17
---

# 0033. Adopt a custom ExternalControlPlane object for the burst cluster

## Context

[0030](0030-externally-managed-control-plane.md) accepted a status nudge as the way to move the `burst` Cluster past initialization. horizon patched the Cluster so infrastructure provisioning proceeded against the externally run k3s control plane. The nudge is imperative, runs outside GitOps, and the core CAPI cluster controller still computed `ControlPlaneInitialized=False` because no control-plane object exposed the contract it reads. Three claims in that record were wrong and are corrected here:

- It reached for the `cluster.x-k8s.io/managed-by` annotation as the switch that tells the core cluster controller to skip control-plane reconciliation. It is not. That annotation is an InfraCluster back-off signal telling an infrastructure provider an external system owns that object, and it does not change how the core controller accounts for control-plane initialization.
- It deferred the structural fix to a CAPH v1.2 release that does not exist. The latest is v1.1.6, which is the version this cluster ran, and the API removal that motivated the wait was scheduled years out, so the deferral rested on a release that was never going to arrive.
- CAPH already supported an externally set `controlPlaneEndpoint`, so the endpoint side was never the gap. The gap is purely the core CAPI initialization accounting, which requires a control-plane object that exposes the contract.

## Decision

Provide a custom `ExternalControlPlane` control-plane object and a controller that reconciles it. The namespaced CRD carries the CAPI contract labels for both served API versions. The controller reads the control-plane endpoint and version from the spec and sets the status the core cluster controller needs: initialized, externally managed, ready, and version. Once a `controlPlaneRef` on the burst Cluster points at this object and the controller populates its status, the core controller observes a genuinely initialized externally managed control plane and horizon's imperative nudge can retire. The controller runs as a single replica alongside the CAPI plane and the objects it serves, with leader election disabled. A second ClusterRole aggregated into the CAPI manager's role grants both read and write access to the resource, because the manager does not only read the status it bubbles: it also patches the object's owner reference and cluster-name label, so read-only access leaves the core controller failing with a forbidden error and the readiness conditions stuck on an internal error. Status access stays read-only, since only the horizon controller writes status.

## Options considered

- Custom `ExternalControlPlane` CRD plus controller, chosen. It exposes the exact contract the core controller reads, lands as ordinary GitOps, and replaces an imperative out-of-band patch with a reconciled object.
- Keep the status nudge indefinitely, rejected. It works but stays imperative, runs outside GitOps, and leaves `ControlPlaneInitialized=False` permanently, so the readiness fields keep misleading anyone who reads them.
- Wait for an upstream externally managed control-plane type, rejected. The deferral in [0030](0030-externally-managed-control-plane.md) pointed at a release that does not exist, and no settled upstream type filled the core CAPI gap on the running versions, so waiting was open-ended.

## Consequences

The burst Cluster gained a real control-plane object whose status the core cluster controller reads, which is correct CAPI readiness accounting without the imperative nudge. The rollout was ordered so that each step was gated on verifying the previous one, because a `controlPlaneRef` added before the controller was populating status would read an empty status and flip initialization back to false. It completed and was verified live, and the nudge was retired. One bootstrap caveat surfaced and is the lasting lesson: the `cluster-capi` Flux Kustomization ran with `wait: true`, so it health-gated on the very Cluster this object initializes, and the first application deadlocked, because the RBAC that lets the manager patch the object could not land while the Kustomization was blocked waiting for the Cluster to become ready. Breaking the deadlock once by applying the committed RBAC directly let the cluster controller proceed, after which Flux converged onto the same content with no drift.

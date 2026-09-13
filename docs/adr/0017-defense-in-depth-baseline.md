---
status: accepted
date: 2026-06-13
---

# 0017. Establish a defense-in-depth baseline

## Context

Network zoning hardens the cluster from the outside, as recorded in [0016](0016-concrete-zoned-ip-scheme.md), but a flat pod network and permissive workloads mean a single compromised container could still reach every service and the host underneath it. The cluster needed an in-cluster baseline that holds even when a workload is breached, layered so that no single control is the only thing standing between an attacker and the rest of the system.

## Decision

A layered baseline is adopted, with each layer narrowing what a compromise can do.

- Default-deny NetworkPolicies per namespace, with least-privilege allows for the traffic each app legitimately needs. This started with a handful of hand-written policy sets and is now a shared Kustomize component that every app references in one line, standardized by [0066](0066-standardize-app-delivery-per-app-kustomizations.md). The two sets deferred here, Traefik and Postgres, both shipped: Traefik carries its own allows for kube-apiserver egress and web ingress, and CloudNativePG carries a set alongside the chart-owned policies in `cnpg-system`.
- securityContext hardening on the workloads. cloudflared runs as non-root with a read-only root filesystem. The `llm` workloads drop all Linux capabilities and run under the RuntimeDefault seccomp profile; full non-root is still deferred for them, because their volumes carry existing ownership that a forced run-as-user would break.
- K3s secret encryption at rest, with `--secrets-encryption` enabled and the existing secrets reencrypted under it.
- Host-level baseline hardening declared once in `hosts/common` so every node inherits it by construction. SSH accepts public keys only, with password and keyboard-interactive authentication disabled alongside the existing `prohibit-password` root policy. The admin kubeconfig is written `0600` through `--write-kubeconfig-mode` rather than its world-readable default. Store growth is bounded by weekly `nix.gc`, `auto-optimise-store`, and a ten-generation boot limit, keeping the small ESP and root partition from filling.

K3s enforces the policies with its embedded kube-router controller, so no extra policy engine is introduced. Runtime threat detection was part of the initial baseline through Falco on all nodes with the eBPF driver and has since been removed, so the current baseline rests on the other layers.

## Options considered

- A layered in-cluster baseline of network policy, workload hardening, runtime detection, and secret encryption, chosen. Each layer is independent, so a gap or a deferral in one does not collapse the others.
- A single strong control, such as network policy alone or a service mesh with mutual TLS. Either is real depth in one dimension, but it leaves runtime behaviour and secrets at rest unaddressed, and a mesh is a large operational surface for this cluster's size.
- Defer all of it until zoning lands. Zoning and in-cluster controls protect against different failure modes, so pairing them was the point.

## Consequences

A breach is contained on several fronts at once, and no single gap collapses the rest: a compromised container has less reach, fewer capabilities, and no writable root where that applies, and secrets stay unreadable from an etcd snapshot alone. The router is the exception to the host baseline, cherry-picking the modules it needs around its own boot and network stack. The standing risk is that the whole policy layer rests on kube-router continuing to enforce it. Three deferrals stay open: full non-root for the `llm` workloads, firmware patching for `rpi-eeprom` and the m920q BIOS, which has no automation behind it, and the permissions on the server PKI under `/var/lib/rancher/k3s/server/tls`. K3s regenerates those certificates and resets their modes on its own schedule, so any chmod or tmpfiles override is undone; tightening them needs a K3s-native mechanism and is left as a separate decision.

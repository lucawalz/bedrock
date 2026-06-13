---
status: accepted
date: 2026-06-13
---

# 0017. Establish a defense-in-depth baseline

## Context

Network zoning hardens the cluster from the outside, as recorded in [0016](0016-concrete-zoned-ip-scheme.md), but a flat pod network and permissive workloads mean a single compromised container could still reach every service and the host underneath it. The cluster needed an in-cluster baseline that holds even when a workload is breached, layered so that no single control is the only thing standing between an attacker and the rest of the system.

## Decision

A layered baseline is adopted, with each layer narrowing what a compromise can do.

- Default-deny NetworkPolicies per application namespace, with least-privilege allows for the traffic each app legitimately needs. This is implemented for `llm`, `n8n`, and `cloudflare-tunnel`. Policies for `traefik` and `postgres` are deferred: Traefik needs kube-apiserver egress worked out, and Postgres ships chart-owned policies that have to be reconciled rather than fought.
- securityContext hardening on the workloads. cloudflared runs as non-root with a read-only root filesystem. The stateful `llm` workloads drop all Linux capabilities and run under the RuntimeDefault seccomp profile; full non-root is deferred for them because their volumes carry existing ownership that a forced run-as-user would break.
- Falco for runtime threat detection, deployed through Flux and running on all nodes using the modern eBPF driver rather than a kernel module.
- K3s secret encryption at rest, with `--secrets-encryption` enabled and the existing secrets reencrypted under it.

kube-router, already the cluster's CNI, enforces the NetworkPolicies, so no extra policy engine is introduced. Firmware patching stays a manual task.

## Options considered

- A layered in-cluster baseline of network policy, workload hardening, runtime detection, and secret encryption, chosen. Each layer is independent, so a gap or a deferral in one does not collapse the others.
- A single strong control, such as network policy alone or a service mesh with mutual TLS. Either is real depth in one dimension, but it leaves runtime behaviour and secrets at rest unaddressed, and a mesh is a large operational surface for this cluster's size.
- Defer all of it until zoning lands. Zoning and in-cluster controls protect against different failure modes, so pairing them was the point rather than sequencing one behind the other.

## Consequences

A breach is contained on several fronts at once: lateral movement is limited by namespace policies, a compromised container has fewer capabilities and, for cloudflared, no writable root, runtime anomalies surface through Falco, and secrets are unreadable from an etcd snapshot alone. The deferrals are recorded honestly and stay open work: NetworkPolicies for `traefik` and `postgres`, full non-root for the `llm` workloads, and firmware patching for `rpi-eeprom` and the m920q BIOS, which stays a manual chore with no automation behind it. The baseline relies on kube-router continuing to enforce policy and on Falco's eBPF driver staying compatible with the node kernels.

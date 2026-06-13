---
status: accepted
date: 2025-10-24
---

# 0002. Declare hosts with NixOS flakes, reconcile the cluster with Flux

## Context

The whole point of the project is that rebuilding a node or recovering from a failure is reading the repository and applying it, not remembering what was done by hand. That requires one reviewable source of truth for both layers: the machines and the workloads on top of them. Two layers, two tools, but the same principle.

## Decision

Hosts are declared as NixOS flakes in `flake.nix` and applied with `nixos-rebuild`. Cluster state is reconciled by Flux v2 from `kubernetes/clusters/home`, so a push to `main` becomes a change to the cluster with no manual `kubectl apply`. The repository is the state.

## Options considered

- Flux v2, chosen. Reconciles straight from Git with no extra UI or surface to run, and Flux manages itself after a one-time bootstrap.
- Argo CD. Capable and popular, but it brings its own UI, CRDs, and a heavier in-cluster presence than a single-operator homelab needs.
- Imperative Ansible. Familiar, but it describes steps rather than desired state, and drift between a playbook and reality is exactly what this project exists to avoid.

## Consequences

The repository is the only way state reaches the cluster, which makes changes reviewable and history meaningful. The cost is a learning curve and a stricter discipline: a broken commit on `main` is a broken cluster, so CI checks the manifests and the Nix evaluation before anything merges.

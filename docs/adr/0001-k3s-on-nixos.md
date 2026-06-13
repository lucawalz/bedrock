---
status: accepted
date: 2025-10-24
---

# 0001. Run the cluster as K3s on NixOS hosts

## Context

The cluster runs on three Lenovo ThinkCentre m920q mini PCs, not a datacenter. Each has limited CPU and memory, so the control plane has to leave room for actual workloads. The hosts are already declared in NixOS, so whatever Kubernetes distribution is chosen has to install and upgrade cleanly from a NixOS module rather than a pile of imperative steps.

## Decision

The cluster is K3s, declared through `modules/k3s/` and run on NixOS hosts. K3s ships as a single binary with a sane set of defaults, which keeps the footprint small enough for three small machines and keeps the NixOS module thin: enable the service, set the role, point it at the join token.

## Options considered

- K3s on NixOS, chosen. One binary, low memory overhead, a first-class NixOS module, and a real Kubernetes API.
- Full kubeadm Kubernetes. The reference distribution, but heavier to run and operate, with more moving parts than three nodes warrant.
- k0s. Comparable in spirit to K3s, but with a weaker NixOS story and no advantage that justified the switch.
- Docker Compose or Nomad. Lighter still, but neither offers the Kubernetes API the rest of the project is built around, so every later choice would have to be reworked.

## Consequences

The overhead is low and node configuration stays declarative. The cost is that K3s bundles components this project does not want: its own servicelb and Traefik are disabled with `--disable`, and local-storage is dropped in favor of Longhorn. Those bundled defaults have to be turned off deliberately, and replacements wired in through Flux.

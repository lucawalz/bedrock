---
status: accepted
date: 2026-06-17
---

# 0034. Add a standalone cluster node snapshot

## Context

CAPH provisions burst and reserved nodes from a single Hetzner snapshot built by the node-image pipeline. That image was shaped exclusively for joining the home cluster as a burst worker. It bakes a hard `agent` role into the k3s service and gates startup behind a tailscale-authkey wait, with all node networking pinned to the `tailscale0` interface. The image cannot form a fresh control plane: a server has no agent to join, the role is wrong, and the tailscale gate blocks boot when no authkey is delivered. A test cluster provisioned a server from this image and k3s never started, because the augment service waited for a tailscale address that never arrived and the baked `agent` role would have been wrong even if it had.

Provisioning a separate standalone cluster, rather than a burst pool inside the home cluster, needs an image that can take either role at runtime and that networks over the Hetzner private NIC instead of a tailnet.

## Decision

A separate `bedrock-cluster-node` image is built by its own Packer pipeline and selected by CAPH through a `caph-image-name=bedrock-cluster-node` label, under the single-image promotion rule from [0029](0029-single-selectable-capi-node-snapshot.md). The image carries no tailscale and no baked role.

The role is taken at runtime from the `INSTALL_K3S_EXEC` value that cluster-api-k3s passes to `/opt/install.sh`. A capture step records whether that value requests a server or an agent, and the k3s launcher selects the matching role, falling back to reading the CAPI-written config when no value was captured. Node networking is derived from the private `10.0.0.0/8` NIC: the augment step writes `node-ip` and `flannel-iface` from that interface and sets the provider id from Hetzner metadata.

This change also adopts a provider-agnostic image-naming convention. Identifiers under repository control name by purpose rather than by provider or bootstrapper. The burst image is renamed from `bedrock-capi-node` to `bedrock-pool-node`, and the standalone image is named `bedrock-cluster-node`. Provider-API names stay untouched: the `HCloudMachineTemplate` and `HetznerCluster` kinds, the `caph-image-name` label key, the `hcloud://` provider id, and the Hetzner metadata endpoints are unchanged.

## Options considered

- Parameterise the burst image into a second mode that can also form a control plane. Rejected to protect the live burst path: a shared module would couple the standalone cluster to every change in the burst image and risk regressing a running pool.
- Rename the burst image to a purpose pair and add a separate standalone image, chosen. It isolates the two roles into independent pipelines and applies the naming convention without touching provider-API names.

## Consequences

Two snapshot pipelines run, each with its own weekly rebuild. The standalone build runs on a Monday cron offset by one hour from the burst build so the two Packer runs do not overlap. The cluster-class default image moves to the standalone `bedrock-cluster-node` image in a later step, gated on the image existing, while the burst node-pool keeps the renamed `bedrock-pool-node` image. Until that step lands, the node-pool and cluster-class manifests keep their existing image reference and nothing in the live burst path changes.

---
status: superseded by 0063
date: 2026-06-17
---

# 0034. Add a standalone cluster node snapshot

## Context

CAPH provisioned burst and reserved nodes from a single Hetzner snapshot shaped exclusively for joining the home cluster as a burst worker. It baked a hard `agent` role into the k3s service, gated startup behind a tailscale-authkey wait, and pinned all node networking to the `tailscale0` interface. The image could not form a fresh control plane: a server has no agent to join, the role was wrong, and the tailscale gate blocked boot when no authkey was delivered. A test cluster provisioned a server from it and k3s never started, because the augment service waited for a tailscale address that never arrived. Provisioning a separate standalone cluster needs an image that can take either role at runtime and that networks over the private NIC instead of a tailnet.

## Decision

A separate `bedrock-cluster-node` image is built by its own Packer pipeline and selected through its own image label, under the single-image promotion rule from [0029](0029-single-selectable-capi-node-snapshot.md). It carries no tailscale and no baked role. The role is taken at runtime from the install command the bootstrap provider passes to the installer: a capture step records whether that value requests a server or an agent, and the k3s launcher selects the matching role, falling back to the bootstrap-written config when no value was captured. Node networking is derived from the private NIC, with the augment step writing the node address and flannel interface from it and setting the provider id from instance metadata. This change also adopts a provider-agnostic image-naming convention: identifiers under repository control name by purpose rather than by provider or bootstrapper, so the burst image becomes `bedrock-pool-node` and the standalone image `bedrock-cluster-node`, while provider-API names such as the machine template kinds, the image label key, the provider id scheme, and the metadata endpoints stay untouched.

## Options considered

- Parameterise the burst image into a second mode that can also form a control plane, rejected to protect the live burst path: a shared module would couple the standalone cluster to every change in the burst image and risk regressing a running pool.
- Rename the burst image to a purpose pair and add a separate standalone image, chosen. It isolates the two roles into independent pipelines and applies the naming convention without touching provider-API names.

## Consequences

Two snapshot pipelines run, each with its own rebuild, offset by an hour so the two Packer runs do not overlap. The cluster-class default image moves to the standalone image in a later step gated on that image existing, while the burst node-pool keeps the renamed one, so nothing in the live burst path changes until then. The standalone image is the one that outlived the burst path: [0063](0063-return-to-single-region.md) retired the CAPI estate, and `bedrock-cluster-node` is the image the surviving pipeline still builds.

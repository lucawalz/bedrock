---
status: accepted
date: 2026-06-13
---

# 0014. Manage the Cloudflare tunnel from the repo and expose only three hosts

## Context

The Cloudflare Tunnel was remotely managed from the Cloudflare dashboard. Its ingress rules lived in Cloudflare's control plane rather than in the repository, so the config was invisible to Git and could drift without review. All eight hosts were routed through it and reachable from the public internet, including admin UIs that have no reason to face the world. The earlier plan in [0011](0011-self-hosted-edge.md) was to drop the tunnel and own the edge through a port-forward, but that publishes the home address and turns the home line into the perimeter, which is a larger commitment than this homelab wants right now.

## Decision

The Cloudflare tunnel is kept, but it runs locally-managed from the repository. The cloudflared deployment reads a config file from a ConfigMap checked into Git, so the full ingress surface is reviewable and reproducible. Only `chat`, `llm`, and `n8n` are exposed publicly; a `http_status:404` catch-all rejects every other hostname. DNS records and Cloudflare Access policies stay dashboard-managed by deliberate choice, because neither is a Kubernetes object and Cloudflare offers no CRD for Zero Trust Access.

This supersedes [0011](0011-self-hosted-edge.md).

## Options considered

- Locally-managed tunnel with in-repo ingress, chosen. Keeps the home address hidden and the third party in the request path, but makes the exposure surface reproducible and reviewable, and narrows it to three hosts plus a deny-all default.
- Own the edge via port-forward, from [0011](0011-self-hosted-edge.md). Full control and no third party, but it publishes the home address and makes the home line the perimeter, which is more exposure than the workloads justify.
- Terraform managing DNS and Access. It would bring those records under code too, but it adds a second IaC tool and its state files to maintain for a handful of stable records, which is not worth the weight.

## Consequences

The exposure surface is now reproducible from the repository and narrowed to three hosts behind a default-deny catch-all. Admin UIs are no longer public; they are reached internally through the Traefik VIP over split-horizon DNS. The tunnel keeps the home address hidden and keeps Cloudflare in the request path, which is accepted. DNS records and Cloudflare Access policies remain manual edits in the dashboard, so those two pieces stay outside the GitOps loop and depend on dashboard discipline rather than review. The credentials for the named tunnel are held in a SOPS-encrypted secret that is part of the trust chain and has to be guarded and rotated like any other secret.

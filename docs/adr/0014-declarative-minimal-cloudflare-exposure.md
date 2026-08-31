---
status: accepted
date: 2026-06-13
---

# 0014. Manage the Cloudflare tunnel from the repo and expose only three hosts

## Context

The Cloudflare Tunnel was remotely managed from the Cloudflare dashboard. Its ingress rules lived in Cloudflare's control plane rather than in the repository, so the config was invisible to Git and could drift without review. All eight hosts were routed through it and reachable from the public internet, including admin UIs that have no reason to face the world. The earlier plan in [0011](0011-self-hosted-edge.md) was to drop the tunnel and own the edge through a port-forward. That publishes the home address and turns the home line into the perimeter, which is a larger commitment than this homelab wants right now.

## Decision

The Cloudflare tunnel is kept, but it runs locally-managed from the repository. The cloudflared deployment reads a config file from a ConfigMap checked into Git, so the full ingress surface is reviewable and reproducible. Only `chat`, `llm`, and `n8n` are exposed publicly; a `http_status:404` catch-all rejects every other hostname. DNS records and Cloudflare Access policies stay dashboard-managed, because neither is a Kubernetes object and Cloudflare offers no CRD for Zero Trust Access.

This supersedes [0011](0011-self-hosted-edge.md).

## Options considered

- Locally-managed tunnel with in-repo ingress, chosen. Keeps the home address hidden and the third party in the request path, but makes the exposure surface reproducible and reviewable, and narrows it to three hosts plus a deny-all default.
- Own the edge via port-forward, from [0011](0011-self-hosted-edge.md). Full control and no third party, but it publishes the home address and makes the home line the perimeter, which is more exposure than the workloads justify.
- Terraform managing DNS and Access. It would bring those records under code too, but it adds a second IaC tool and its state files to maintain for a handful of stable records, which is not worth the weight.

## Consequences

The exposure surface is now reproducible from the repository and narrowed to three hosts behind a default-deny catch-all. Admin UIs are no longer public; they are reached internally through the Traefik VIP over split-horizon DNS. The tunnel keeps the home address hidden and keeps Cloudflare in the request path, which is accepted. DNS records and Cloudflare Access policies remain manual edits in the dashboard, so those two pieces stay outside the GitOps loop and depend on dashboard discipline. The credentials for the named tunnel are held in a SOPS-encrypted secret that is part of the trust chain and has to be guarded and rotated like any other secret.

## Update 2026-07-25

The tunnel no longer carries the three hosts named above. It carries four, `chat`, `n8n`, `lucawalz.dev`, and `rancher`, and no longer carries `llm`. Two later decisions changed the list without amending this record, and a third change pruned a route that had gone dead, so the count in the title and in the Decision has not matched the config since 2026-06-14.

**Update 2026-07-31:** the tunnel now carries three hosts. `n8n` was removed with the application
itself, which had never been used and held no workflows, credentials or executions.

`lucawalz.dev` joined on 2026-06-14. The blog first went out at `blog.syslabs.dev` and moved to the apex the same day under [0021](0021-public-blog-portfolio-domain.md), since folded into the consolidated blog record [0019](0019-self-hosted-static-blog.md). The apex falls outside the `*.syslabs.dev` wildcard certificate Traefik serves as its default, so that one ingress rule carries `noTLSVerify` on its origin request.

`rancher.syslabs.dev` joined on 2026-07-05 under [0059](0059-outbound-only-peers-via-public-rancher.md), so that a peer cluster could register outward against the hub without an inbound path into home. It is guarded by Cloudflare Access with multi-factor authentication on the human-facing paths, with a second, narrow Access application bypassing only the agent registration paths. That is a wider exposure than the workload-only hosts this record contemplated, and the compensating control is Access rather than the tunnel itself.

`llm.syslabs.dev` was pruned on 2026-07-12. It had fronted a LiteLLM gateway that was removed on 2026-06-21, so for three weeks the tunnel forwarded a hostname with no router behind it. A LiteLLM gateway returned on 2026-07-13 at `litellm.syslabs.dev` and is internal only, so it is not in the tunnel and is not a replacement for the pruned route.

The decision itself is unchanged. The ingress surface is still declared in the repository, every public host is still added by a reviewed commit, and the `http_status:404` catch-all still rejects every hostname that is not listed, so this record is amended rather than superseded. The title and the Decision keep the count as it stood on 2026-06-13; the list in this update is the current one.

**Update 2026-08-31:** the tunnel carries four hosts. `grocy.syslabs.dev` joined under [0079](0079-public-grocy-with-scoped-api-bypass.md), so that a phone can reach the grocery inventory from a shop. Its browser interface is behind Cloudflare Access; a second, narrow Access application bypasses only the `/api/` prefix, which the native client needs and which Grocy protects with an application-issued API key. That is the same shape as the rancher exposure and the same compensating control.

---
status: accepted
date: 2026-06-13
---

# 0014. Manage the Cloudflare tunnel from the repo and expose only three hosts

## Context

The Cloudflare Tunnel was remotely managed from the Cloudflare dashboard. Its ingress rules lived in Cloudflare's control plane rather than in the repository, so the config was invisible to Git and could drift without review. All eight hosts were routed through it and reachable from the public internet, including admin UIs that have no reason to face the world. The earlier plan in [0011](0011-self-hosted-edge.md) was to drop the tunnel and own the edge through a port-forward, which publishes the home address and turns the home line into the perimeter, a larger commitment than this homelab wants.

## Decision

The Cloudflare tunnel is kept, but it runs locally-managed from the repository, superseding [0011](0011-self-hosted-edge.md). The cloudflared deployment reads a config file from a ConfigMap checked into Git, so the full ingress surface is reviewable and reproducible. That `config.yaml` is the host list: the public surface is whatever it names and nothing else, because a `http_status:404` catch-all rejects every other hostname. It currently carries `chat`, `rancher`, and `lucawalz.dev`, and the list has moved several times since this record was written, each move a reviewed commit. DNS records and Cloudflare Access policies stay dashboard-managed, because neither is a Kubernetes object and Cloudflare offers no CRD for Zero Trust Access.

`rancher.syslabs.dev` is the widest of them and the one to watch. It joined so that a peer cluster could register outward against the hub without an inbound path into home, and it is guarded by Cloudflare Access with multi-factor authentication in front of Authentik forward auth. A narrow second Access application and a matching IngressRoute rule once bypassed forward auth for `/ping`, `/healthz`, `/v3/connect` and `/v3/import`; both were removed on 2026-09-12 once Rancher managed only the in-cluster `local` cluster and nothing was still using them. Importing another cluster means restoring a scoped bypass, or pointing the `server-url` Setting and `cattle-fleet-system/fleet-controller`'s `apiServerURL` at an internal address, as a deliberate step rather than a surprise.

## Options considered

- Locally-managed tunnel with in-repo ingress, chosen. Keeps the home address hidden and the third party in the request path, but makes the exposure surface reproducible and reviewable, and narrows it to a named host list plus a deny-all default.
- Own the edge via port-forward, from [0011](0011-self-hosted-edge.md). Full control and no third party, but it publishes the home address and makes the home line the perimeter, which is more exposure than the workloads justify.
- Terraform managing DNS and Access. It would bring those records under code too, but it adds a second IaC tool and its state files to maintain for a handful of stable records, which is not worth the weight.

## Consequences

The exposure surface is reproducible from the repository and narrowed to a short host list behind a default-deny catch-all. Admin UIs are no longer public; they are reached internally through the Traefik VIP over split-horizon DNS. The tunnel keeps the home address hidden and keeps Cloudflare in the request path, which is accepted. Adding or removing a host is therefore a commit here and a matching dashboard change, so half of every exposure change depends on dashboard discipline. The apex `lucawalz.dev` falls outside the `*.syslabs.dev` wildcard Traefik serves as its default, so that one ingress rule carries `noTLSVerify` on its origin request. The credentials for the named tunnel are held in a SOPS-encrypted secret that is part of the trust chain and has to be guarded and rotated like any other secret.

# 11. Serve through Traefik and a Cloudflare tunnel

Date: 2026-11-07

## Status

Accepted

## Context

Two services are meant for the public: the blog at `lucawalz.dev` and Open WebUI at `chat.syslabs.dev`. Everything else is for the owner only. The home connection should not accept inbound traffic from the internet, and internal names should resolve and carry valid certificates from the LAN and the tailnet alike.

## Decision

- Traefik is the only ingress. MetalLB announces it on the service VIP `10.20.0.50`, and every route is a Traefik `IngressRoute` matched by host.
- cert-manager issues one wildcard certificate for `syslabs.dev` and `*.syslabs.dev` from Let's Encrypt over Cloudflare DNS-01, and Traefik serves it as its default certificate. No internal host needs a public DNS record or an open port to get a certificate.
- Internally, AdGuard on the router answers every `*.syslabs.dev` name with the VIP ([0002](0002-declare-every-host-with-nixos-flakes.md)). Admins reach it from the LAN or over Tailscale.
- Publicly, `cloudflared` runs in the cluster and holds an outbound tunnel to Cloudflare. Its ingress rules in git route only `chat.syslabs.dev` and `lucawalz.dev` to Traefik and answer 404 for anything else. Cloudflare terminates public TLS; the apex is outside the wildcard, so the tunnel skips origin verification for it.
- A Cloudflare Access application named "chat", self-hosted at `chat.syslabs.dev`, guards the public chat host. Its one Allow policy, named "MFA", has a 6 hour session duration. It includes the owner's email and requires the GitHub login method. The policy lives in the Cloudflare dashboard, not in git. The second factor comes from the GitHub account's own two-factor setting, which Cloudflare does not check. Open WebUI keeps its own login behind Access.
- Traefik's Service keeps `externalTrafficPolicy: Cluster`, so every client arrives as the node holding the VIP and an `ipAllowList` cannot tell clients apart. The registry at `registry.syslabs.dev` therefore has none; it serves anonymous reads of mirrored public images and has no user that can push.
- Admin UIs sit behind forward-auth ([0010](0010-sign-in-through-pocket-id-and-oauth2-proxy.md)) and are never routed through the tunnel.

## Consequences

- No port is forwarded from the internet to the cluster, and exposing a host publicly takes a change to the tunnel ingress in git.
- The tunnel's public DNS records and Cloudflare Access applications are still managed in the Cloudflare dashboard, not from git.
- Traefik logs and middlewares see the VIP node, not the client, so no rule can key on a client address. Closing anonymous registry reads would go through zot's own access policy and registry credentials on the nodes, not through Traefik.
- Internal access depends on the router's DNS. A device that does not use it resolves the public records instead, which exist only for the two public hosts.

## Accepted risk

Open WebUI v0.13.4 still ships PyJWT 2.13.0 (CVE-2026-102268, fixed in 2.14.0) and Authlib 1.7.2 (CVE-2026-96760). The same image carries further fixable criticals that issue #316 tracks. The release is deployed anyway, because the affected authentication libraries sit behind two gates:

- On the tunnel path, the Cloudflare Access "MFA" policy admits only the owner's GitHub identity before a request reaches Open WebUI.
- On the LAN path, Open WebUI's own login is the only gate, and only LAN and tailnet clients reach it.

Revisit when the first upstream release ships PyJWT 2.14 or later, which the image-scan issue #316 surfaces. The image is then bumped and this section removed.

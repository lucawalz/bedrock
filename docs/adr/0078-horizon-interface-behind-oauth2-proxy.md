---
status: accepted
date: 2026-08-23
---

# 0078. Put the horizon interface behind oauth2-proxy and an Authentik OAuth2 provider

## Context

Every gated host in this estate is served the same way. Traefik matches the host, the shared `authentik-forward-auth` middleware asks the embedded outpost whether the request carries a session, and the application behind it trusts the answer. The horizon interface was wired that way first, and for a dashboard that only has to be reached by a signed-in operator, it is enough.

The horizon interface is not that. It impersonates the caller against the API server on every request, so it has to know who the caller is with certainty rather than accept an upstream's assertion. That means verifying a token itself: signature against a key set it fetches, plus issuer, audience and expiry. The forward-auth middleware already copies `X-authentik-jwt` onto every gated request, so the shape looked right.

It is not verifiable. An Authentik proxy provider signs that token HS256 with the provider's own client secret, and `ProxyProviderSerializer` exposes no `signing_key` field, so there is no way to give the provider an asymmetric key from a blueprint. The provider's JWKS endpoint returns an empty key set and its metadata advertises HS256 alone. Verifying the token would require the interface to hold the proxy provider's client secret, which makes the interface a second copy of the gate's own credential and defeats the reason for verifying at all. An attempt to set `signing_key` on the proxy providers was committed and reverted, because Authentik discards unknown serializer attributes silently and the result was configuration that implied a capability the system did not have.

`OAuth2ProviderSerializer` does expose `signing_key`, and an OAuth2 provider publishes a real JWKS signed by the referenced certificate keypair. The credential to verify against is then a public key, which is what the interface needs and the only thing it should ever hold.

## Decision

Serve `horizon.syslabs.dev` through oauth2-proxy against an Authentik OAuth2 provider, for this one host, and leave every other gated host on forward auth.

The blueprint's `prov-horizon` entry becomes an `authentik_providers_oauth2.oauth2provider` with a `signing_key` referencing the existing `authentik Self-signed Certificate` keypair, a strict redirect URI at `https://horizon.syslabs.dev/oauth2/callback`, and `include_claims_in_id_token` so the claims the interface impersonates on arrive in the token itself rather than through a userinfo call nothing makes on its behalf. The entry leaves the embedded outpost's provider list, because an OAuth2 provider is not served by an outpost.

The client id is pinned to `horizon-interface` rather than generated. The audience the interface verifies is the client id, so a generated value would have to be read out of a running Authentik and copied into a manifest by hand, which makes the audience a piece of cluster state that the repository cannot state. A client id is public in every authorize redirect, so pinning it costs nothing and makes the interface's required audience a declared constant. The client secret stays generated out of band and is supplied to both sides from the private secrets repository described in [0060](0060-private-secrets-repo-per-cluster-keys.md), reaching Authentik through the same `!Env` mechanism the GitHub source already uses.

Traefik routes the host to oauth2-proxy and no longer attaches the forward-auth middleware to it, because oauth2-proxy now performs the authentication. oauth2-proxy upstreams to the interface and passes the id token as an `Authorization: Bearer` header, which is the header and format the interface's verifier expects by default.

oauth2-proxy reaches Authentik through the ingress address rather than the in-cluster service. Authentik derives a token's issuer from the request it was minted through, so a server-to-server call over `authentik-server.authentik.svc.cluster.local` would issue tokens whose issuer does not match the one the interface is configured with, and the verification would fail on a value nothing in the manifests would explain. Going out through `10.20.0.50` keeps one issuer for the browser and the proxy alike, at the cost of one hairpin through Traefik that the homepage dashboard already takes for the same reason.

The network path is stated end to end and nothing is left implicit. Traefik reaches oauth2-proxy on 4180 and only oauth2-proxy. oauth2-proxy reaches the interface on 8082 and Authentik on 443. The interface is no longer reachable from the Traefik namespace at all, so a route added later cannot skip the proxy by accident.

The chart ships its own NetworkPolicy for the interface, and this release turns it off. It admits whole namespaces and defaults to the Traefik namespace, which stopped being the correct source the moment a proxy was placed in between. The admissible source is now one pod set inside the interface's own namespace, which a namespace list cannot name. Two policies each describing half a path is worse than one describing all of it, so the policies in this repository are the only description.

The interface's impersonation grant is narrowed to the single user who holds an account on this instance. The chart defaults to an unrestricted `impersonate` verb, which is a path to any identity in the cluster, including cluster-admin, for anything that can reach the interface's ServiceAccount. There is one account here and no groups, so the grant is written to say so.

## Options considered

- Forward auth with the interface verifying `X-authentik-jwt`, the original design. Rejected on evidence: the token is HS256 signed with the proxy provider's client secret, the JWKS is empty, and no blueprint attribute changes that. Verification would mean handing the interface the gate's own secret.
- Forward auth with the interface trusting `X-authentik-username` without verification. Rejected. The interface impersonates on the strength of that header, so anything that can reach the pod can name any user. It converts a NetworkPolicy from defence in depth into the only thing standing between an in-cluster pod and cluster-admin impersonation.
- An Authentik OAuth2 provider with the interface performing the login flow itself. This removes a component and is the smaller deployment. Rejected because it puts a full authorization code flow, a session cookie, a state parameter and a token refresh loop inside the interface, which is a large amount of security-sensitive code to own for a single dashboard when a maintained proxy does exactly that job. The interface keeps only the verification half, which is the part that has to be there anyway.
- oauth2-proxy in front, chosen. The interface gains an id token it can verify against a published key set and keeps no login code, and the estate gains one component in one namespace rather than a change to how every other host is gated.
- Migrating every gated host to oauth2-proxy for consistency. Rejected as scope this decision does not need. Forward auth is adequate for hosts that only need a signed-in visitor, and moving eleven of them to gain uniformity would trade a working path for a larger one.

## Consequences

The estate now gates hosts two ways, and which way a host uses is a property of whether the application behind it verifies identity itself. That is a real inconsistency and it is documented here so it reads as a decision rather than drift. The horizon namespace carries a second workload whose only job is authentication, and a failure in it takes the interface offline while the operator itself keeps reconciling, because the two are separate deployments.

The pinned client id makes the audience a declared value in both the blueprint and the release, so a change to one without the other is a token rejection rather than a silent mismatch. The client secret is now required in two places, the `authentik` secret in the Authentik namespace and the `horizon-oauth2-proxy` secret in the horizon namespace, and the two have to hold the same value. Kubernetes secrets are namespaced and this estate runs no mirroring controller, so that duplication is the mechanism rather than an oversight.

The `values` block on the horizon release names an interface the published chart does not have yet. It applies as soon as the chart ships and does nothing before then, which keeps the wiring reviewable in one change rather than split across a release boundary.

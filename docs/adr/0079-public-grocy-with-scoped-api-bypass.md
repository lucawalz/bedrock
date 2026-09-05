---
status: superseded by 0080
date: 2026-08-31
---

# 0079. Expose Grocy publicly with a path-scoped forward-auth bypass

> Superseded by [0080](0080-retire-grocy.md).

## Context

Grocy tracks groceries, fridge contents and expiry dates, and its value depends on being usable from a phone in a shop. The browser interface can sit behind Authentik like every other internal application, but the native iOS client cannot: it authenticates with an application-issued API key sent as a `GROCY-API-KEY` header and has no way to complete an interactive forward-auth flow. Leaving the whole host behind forward auth would make the application work in a browser and fail in the app that justifies deploying it.

The estate is otherwise default deny. Three hosts are public through the Cloudflare tunnel under [0014](0014-declarative-minimal-cloudflare-exposure.md), and only one of them, `rancher.syslabs.dev`, already carries a path-scoped bypass for an unattended client, recorded in [0059](0059-outbound-only-peers-via-public-rancher.md). Adding a fourth public host with an unauthenticated path prefix is a change in security posture rather than a routine configuration change, so it belongs in the record.

## Decision

`grocy.syslabs.dev` is published through the existing Cloudflare tunnel. Its Traefik IngressRoute carries two routes on one host: a route matching `PathPrefix(/api/)` at priority 20 with no middleware, and a catch-all at priority 10 carrying `authentik-forward-auth`. Cloudflare Access sits in front of both, with an application over the host requiring multi-factor authentication and a second, narrow application bypassing only `/api/`. This mirrors the rancher arrangement exactly.

The bypass is safe on three independent legs, each verified against the shipped code rather than assumed.

The prefix is exact. Traefik matches the literal `/api/`, so `GET /api`, which is Grocy's Swagger interface and a browser page, does not match the bypass and stays behind forward auth.

Grocy protects the bypassed prefix itself. Its `BaseAuthMiddleware` computes an `IsApiRoute` flag from the same literal `/api/` prefix and returns a bare 401 rather than a redirect for any unauthenticated request under it, including paths that match no route. Only the route names `root` and `login` are treated as public. The bypass is therefore additive at the edge and self-protecting at the application.

The key is strong. Grocy generates API keys as 24 random bytes from a cryptographically secure source, rendered as 48 hexadecimal characters. Guessing one is not a practical attack, which is what makes an internet-reachable, key-authenticated prefix acceptable here.

The Grocy administrator password is changed from its shipped default before the tunnel entry lands, because Grocy offers no way to seed a credential from a manifest and publishing first would expose a default-credentialed instance behind the bypass.

## Options considered

- Two routes with a path-scoped bypass, chosen. The browser interface keeps the same single sign-on gate as every other application, while the one client that cannot use it reaches exactly the prefix it needs and no more. The cost is a public prefix whose only application-layer control is an API key, mitigated by the key's strength, by Grocy returning 401 on that prefix itself, and by Cloudflare Access in front.
- Grocy's `ReverseProxyAuthMiddleware`, rejected. Pointing `AUTH_CLASS` at it would remove the double login by trusting a header Authentik sets. It is unsafe in this arrangement precisely because of the bypass: the `/api/` route does not pass through forward auth, so a client could set the trusted header itself and be authenticated as any user on every API route. The double login is the cheaper cost.
- A separate hostname for the API, rejected. Splitting the API onto its own host would keep one gate per host and avoid priorities entirely, but the client expects a single base URL for both the interface and the API, so it would not work.
- Keeping Grocy internal and reaching it over Tailscale, rejected. It is the safest option and it defeats the purpose: the phone has to work in a shop, on mobile data, without the owner remembering to bring up an overlay first.
- A rate limit on the bypassed prefix, rejected. Brute force against a key of this size is not a credible threat, and a middleware that guards against nothing is debt.

## Consequences

A fourth host is public, and one prefix of it is reachable without any edge authentication beyond Cloudflare Access. That prefix is guarded by an application-issued key and by Grocy's own middleware, and the exposure is declared in the repository like every other tunnel route, so it is reviewable in a diff.

Authentik and Grocy both present a login, so first use in a browser prompts twice. [0038](0038-authentik-sso-for-internal-dashboards.md) already accepted that trade.

Cloudflare Access policies and the DNS record stay dashboard-managed, which [0014](0014-declarative-minimal-cloudflare-exposure.md) records as deliberate, so two pieces of this exposure live outside the GitOps loop and depend on dashboard discipline.

The API key never expires by default. Rotating it means generating a new one in the interface and updating the client, and nothing in the repository tracks that it happened.

## Update 2026-08-31

The Traefik forward-auth gate described above was removed on the day it was
deployed. It could never have worked for a browser outside the network: Authentik
issues its redirect to `auth.syslabs.dev`, which has no public DNS record and is
not carried by the tunnel, so a client on mobile data authenticated against
Cloudflare Access and then landed on a hostname it could not resolve. The pattern
was copied from the rancher route, where the flaw is latent because the public
paths there are used by an unattended agent that never follows the redirect.

The route is now a single rule with no middleware. The layered argument is
unchanged in substance but the layers moved. Cloudflare Access gates the browser
interface from outside, with a policy requiring a named identity, the GitHub login
method, and a German source country. The narrow Access application still bypasses
only the `/api/` prefix for the native client. Grocy's own login gates the
interface everywhere, including on the tailnet, and its `BaseAuthMiddleware` still
returns a bare 401 for any unauthenticated request under `/api/`. The path-scoped
bypass therefore survives at the edge rather than at the router.

Two consequences follow. Reaching the interface from the tailnet no longer
involves single sign-on, so Grocy's own credential is the only gate there, which
matches how `chat.syslabs.dev` has always worked and is the estate's established
pattern for a public human-facing application. And the double login recorded above
is gone, so the reference to [0038](0038-authentik-sso-for-internal-dashboards.md)
no longer applies to this record.

The proxy provider and application that Authentik held for this host were removed
in the same change, since a provider for an application that never calls it is
drift rather than configuration.

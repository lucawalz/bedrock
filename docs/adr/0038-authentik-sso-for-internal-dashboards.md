---
status: accepted
date: 2026-06-19
---

# 0038. Authentik single sign-on for internal dashboards

## Context

The home cluster exposes a row of internal dashboards over the VPN: Flux, Velero, the Traefik dashboard, Prometheus, Alertmanager, Grafana, Longhorn, pgAdmin, Rancher, ntfy, and the Homepage start page. Each one arrived with whatever auth its chart or ingress happened to carry. Five sat behind a per-app Traefik basic-auth middleware ([0008](0008-traefik-ingress.md), [0018](0018-internal-dashboard-and-router-metrics.md)), sharing a single credential whose password had been lost; the rest were unauthenticated and relied entirely on the network boundary. There was no identity behind any of them, no single sign-on, no second factor, and no record of who opened what.

[0013](0013-edge-auth-proxy.md) put an authenticating proxy at the public edge, but that record is about the boundary in front of public apps, not the internal dashboards reached over the tunnel. The dashboards needed their own identity layer: one "Login with GitHub", a single operator account and no other, real sessions rather than a re-prompt on every host, a path to MFA, and an admin UI to manage it, all expressed declaratively like the rest of the repository.

## Decision

Run Authentik as the cluster's identity provider and gate every internal dashboard behind it with Traefik forward authentication.

Authentik (chart 2026.5.3) is installed by a Flux `HelmRelease` in the `authentik` namespace: server and worker, a self-hosted Redis (the chart bundles only Postgres), and the `authentik` database provisioned on the shared Postgres by an init Job. It is reachable at `auth.syslabs.dev` through a Traefik `IngressRoute`. All of its configuration is config-as-code through blueprints mounted from a ConfigMap, with secrets injected as environment variables from a SOPS secret and referenced in the blueprints by tag.

Login is GitHub only, restricted to a single account. A GitHub OAuth source provides the social login. A custom source enrollment flow writes new users as internal so they can reach the Authentik UI, and its first stage is a Deny stage gated by an expression policy that passes only the one allowed GitHub username. Because the restriction sits at enrollment, no other identity can ever obtain a session, so the gate holds without any per-application policy. The login screen keeps its username field, so the local bootstrap admin stays available as break-glass.

Gating is domain-level forward auth. One proxy provider per dashboard host runs in `forward_domain` mode with `cookie_domain` set to the parent `syslabs.dev`, so a single session cookie covers every host, and all providers attach to the embedded outpost that runs inside the Authentik server. The outpost's `/outpost.goauthentik.io/` endpoint is served centrally on `auth.syslabs.dev`, which the existing IngressRoute already carries, so each protected host needs only a Traefik `forwardAuth` middleware and no outpost route of its own. The middleware address is the in-cluster Authentik service, so Traefik cross-namespace references stay disabled and a middleware is replicated into each dashboard namespace. Grafana and Longhorn, which shipped as plain Ingress objects, are converted to IngressRoutes so they can carry the middleware. With forward auth proven on every host the per-app basic-auth middlewares and their SOPS secrets are removed.

## Options considered

- Authentik as a full identity provider, chosen. It brings GitHub social login, a real session and admin UI, MFA capability, and an audit trail, and its blueprints keep the whole configuration declarative. The cost is weight (server, worker, Redis, a database) and a blueprint model with sharp edges that took live iteration to get right.
- Authelia, rejected. It is a lighter forward-auth companion, but it offers no management UI and a weaker social-login story, and the goal explicitly included a "Login with GitHub" and a console to manage identity.
- oauth2-proxy, rejected. A single-provider forward-auth proxy is simpler than an identity provider, but it has no notion of applications, no management UI, and no room to grow into MFA or more users without replacing it.
- Keeping per-app basic-auth, rejected. The shared password was lost, every host re-prompted, and there was no identity, no MFA, and no audit. It is the state this record sets out to leave.

## Consequences

One GitHub login now stands in front of all eleven internal dashboards, sharing a single `syslabs.dev` session so a second host does not prompt again. Access is held to one account at enrollment, the enrolled user is internal enough to use the Authentik console, MFA is available when wanted, and Authentik records the logins. The bootstrap admin remains as a local break-glass through the login panel, recoverable from the cluster if the panel itself is ever lost.

Domain-level forward auth keeps the wiring small. Because the outpost endpoint lives on the auth host, no dashboard needs an outpost route and Traefik cross-namespace references stay off, at the price of one small `forwardAuth` middleware copied into each dashboard namespace. The restriction living at enrollment rather than on each application is the simplest posture that is still correct for a single operator; adding more people later means moving specific apps to per-app providers with their own policies.

The blueprint work surfaced several version-specific traps worth recording so the next change does not rediscover them: the environment tag is `!Env`, not `!ENV`; an OAuth source's credentials are `consumer_key` and `consumer_secret`, not `client_id` and `client_secret`; a policy bound directly to a source does not run during the OAuth callback, so the single-user gate is enforced in the enrollment flow instead; source enrollment creates external users by default, which cannot open the Authentik UI; and a policy binding whose target is a Flow is not idempotent under the blueprint importer, so the gate is expressed as a Deny stage bound to a stage binding by key within one blueprint.

Grafana still presents its own login behind the Authentik gate, a double prompt left in place for now; wiring Grafana to trust the `X-authentik-*` headers would fold it into the single sign-on later. This record sits alongside [0013](0013-edge-auth-proxy.md), which authenticates the public edge, by adding identity at the internal dashboard layer, and it retires the basic-auth introduced with [0008](0008-traefik-ingress.md) and [0018](0018-internal-dashboard-and-router-metrics.md) under the defense-in-depth baseline of [0017](0017-defense-in-depth-baseline.md).

---
status: accepted
date: 2026-06-19
---

# 0038. Authentik single sign-on for internal dashboards

## Context

The home cluster exposes a row of internal dashboards over the overlay, and each one arrived with whatever auth its chart or ingress happened to carry. Several sat behind a per-app Traefik basic-auth middleware ([0008](0008-traefik-ingress.md), [0018](0018-internal-dashboard-and-router-metrics.md)), sharing a single credential whose password had been lost. The rest were unauthenticated and relied entirely on the network boundary. There was no identity behind any of them, no single sign-on, no second factor, and no record of who opened what. [0013](0013-edge-auth-proxy.md) put an authenticating proxy at the public edge, but that record is about the boundary in front of public apps, not the internal dashboards. The dashboards needed their own identity layer, expressed declaratively like the rest of the repository, offering one GitHub login and a single operator account, holding one session across every host, leaving a path to MFA, and providing an admin UI to manage identity.

## Decision

Run Authentik as the cluster's identity provider and gate every internal dashboard behind it with Traefik forward authentication. A Flux HelmRelease installs the server, the worker, and a self-hosted Redis, since the chart bundles only Postgres. Its database is a declarative `Database` resource under [0046](0046-cloudnative-pg-declarative-postgres.md), replacing the init Job it began as. Authentik answers at `auth.syslabs.dev`, and its whole configuration is blueprints mounted from a ConfigMap with secrets injected from a SOPS secret.

Login is GitHub only, through a GitHub OAuth source, and the enrollment flow denies every username but the one allowed. Putting the restriction at enrollment rather than on each application means no other identity can obtain a session, and no per-application policy is needed. The login screen keeps its username field, leaving the bootstrap admin as break-glass.

Gating is domain-level forward auth. One proxy provider per dashboard host runs in forward-domain mode with the cookie domain set to the parent domain, so one session cookie covers every host, and every provider attaches to the outpost embedded in the Authentik server. Because that outpost endpoint is served centrally on the auth host, a protected host needs only a forward-auth middleware and no outpost route. The middleware addresses the in-cluster service, so Traefik cross-namespace references stay off and a copy lives in each dashboard namespace. Once forward auth was proven everywhere, the per-app basic-auth middlewares and their secrets were removed.

## Options considered

- Authentik as a full identity provider, chosen. It brings GitHub social login, a real session and admin UI, MFA capability, and an audit trail, and its blueprints keep the whole configuration declarative. The cost is weight, a server, worker, Redis, and a database, and a blueprint model with sharp edges that took live iteration to get right.
- Authelia, rejected. It is a lighter forward-auth companion, but it offers no management UI and a weaker social-login story, and the goal explicitly included a GitHub login and a console to manage identity.
- oauth2-proxy, rejected. A single-provider forward-auth proxy is simpler than an identity provider, but it has no notion of applications, no management UI, and no room to grow into MFA or more users without replacing it.
- Keeping per-app basic-auth, rejected. The shared password was lost, every host re-prompted, and there was no identity, no MFA, and no audit. It is the state this record sets out to leave.

## Consequences

One GitHub login stands in front of the internal dashboards, sharing a single session so a second host does not prompt again, and access is held to one account at enrollment. The enrolled user is internal enough to use the Authentik console, MFA is available when wanted, and logins are recorded. Domain-level forward auth keeps the wiring small, at the price of one small middleware copied into each dashboard namespace, and the restriction living at enrollment rather than on each application is the simplest posture that is still correct for a single operator; adding more people later means moving specific apps to per-app providers with their own policies. Grafana is the one dashboard that stays outside the gate: its IngressRoute carries no forward-auth middleware and it presents its own login instead, and the same host serves the public dashboard link the bar panel in [0054](0054-bar-display-grafana-kiosk-and-corrected-edid.md) is driven by, which a host-level gate would block. This record sits alongside [0013](0013-edge-auth-proxy.md), which authenticates the public edge, by adding identity at the internal dashboard layer, and it retires the basic-auth introduced with [0008](0008-traefik-ingress.md) and [0018](0018-internal-dashboard-and-router-metrics.md) under the defense-in-depth baseline of [0017](0017-defense-in-depth-baseline.md).

The blueprint work surfaced several version-specific traps worth recording so the next change does not rediscover them. The environment tag is `!Env`, not `!ENV`. An OAuth source's credentials are `consumer_key` and `consumer_secret`, not `client_id` and `client_secret`. A policy bound directly to a source does not run during the OAuth callback, so the single-user gate is enforced in the enrollment flow instead. Source enrollment creates external users by default, which cannot open the Authentik UI. A policy binding whose target is a Flow is not idempotent under the blueprint importer, so the gate is expressed as a Deny stage bound to a stage binding by key within one blueprint.

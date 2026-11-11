---
status: accepted
date: 2026-11-07
---

# 0010. Sign in through Pocket ID and oauth2-proxy

## Context

Several admin UIs (Flux, Homepage, Longhorn, Prometheus, Alertmanager, ntfy, paperless-gpt, the Traefik dashboard) ship with weak or no authentication of their own. One person administers the cluster. The previous identity provider was a large stack whose configuration lived mostly in its database rather than in git.

## Decision

- Pocket ID at `id.syslabs.dev` is the identity provider. It signs in with passkeys only, stores its state in its own database on the shared Postgres cluster ([0007](0007-share-one-cloudnativepg-cluster-with-per-app-databases.md)), and is reachable from the LAN and the tailnet only.
- OIDC clients are declared in git. `kubernetes/infrastructure/controllers/pocket-id/clients/clients.json` lists them, and an idempotent Job upserts each one through the Pocket ID API with a static API key and client secrets taken from `bedrock-secrets`.
- Users cannot edit their own account, so only the admin sets names and email addresses. `EMAILS_VERIFIED` stays on for that reason: no SMTP exists to verify an address, oauth2-proxy refuses unverified ones, and with own-account edits off no user can claim an address the admin did not set.
- One oauth2-proxy at `auth.syslabs.dev` is the only OIDC client. Its cookie covers `.syslabs.dev`, and it admits only the addresses in an email allowlist kept in a SOPS Secret. It requires a verified email and is not relaxed to accept unverified ones.
- Apps opt into protection with the `kubernetes/components/forward-auth` component, which adds one Traefik forward-auth Middleware pointing at oauth2-proxy.
- Apps with a proper login of their own (Grafana, Paperless, Open WebUI, LiteLLM, AdGuard) keep it. LiteLLM also sits behind forward-auth, so its login is a second layer. Open WebUI is public at `chat.syslabs.dev`, and Pocket ID stays internal rather than being exposed so that it could protect it.

## Consequences

- Protecting a new app is one component line, and the identity configuration is rebuilt from git apart from the user and passkey.
- After a rebuild the owner claims Pocket ID's `/setup` page and marks the owner's email verified in its admin UI, since there is no SMTP to verify it. Until then forward-auth answers 500. The claim window is open to the home LAN.
- A rotated client secret reaches Pocket ID only when the Job next runs, up to about 70 minutes later.

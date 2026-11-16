---
status: accepted
date: 2026-11-16
---

# 0018. Keep passwords in Vaultwarden behind Pocket ID

## Context

The owner's passwords need a home that the cluster backs up, restores and patches like every other app, and that the Bitwarden browser extension and iPhone app can use. A hosted password manager would keep the vault outside the backups and restore drills ([0012](0012-back-up-off-site-to-cloudflare-r2-and-test-restores.md)). A vault is the most sensitive data in the cluster, so it gets the narrowest exposure and network reach of any app.

## Decision

- Vaultwarden runs at `vault.syslabs.dev` from `docker.io/vaultwarden/server`, pinned by digest, on the app-template chart scaffolded by `just new-app` ([0013](0013-keep-each-app-self-contained-and-scaffold-new-ones.md)). It runs as UID and GID 1000 on port 8080 with a read-only root filesystem. Renovate holds its minors and patches for review ([0014](0014-pin-versions-and-update-them-with-renovate.md)).
- Its database `vaultwarden` lives on the shared Postgres cluster under the `sameuser` rule, so the WAL archive and the nightly encrypted dumps cover it ([0007](0007-share-one-cloudnativepg-cluster-with-per-app-databases.md)). `scripts/restore-test.sh` compares `vaultwarden.__diesel_schema_migrations` between production and each restore. Attachments, Sends and the server's signing key live on a `longhorn-encrypted` volume with snapshots and off-site backups.
- It is served by the internal Traefik only. There is no tunnel route and no forward-auth, because the Bitwarden clients call the API directly and cannot pass an oauth2-proxy redirect.
- Sign-in goes through Pocket ID ([0010](0010-sign-in-through-pocket-id-and-oauth2-proxy.md)) with the confidential client `vaultwarden`: PKCE, the callback `https://vault.syslabs.dev/identity/connect/oidc-signin`, restricted to `admins`. Pocket ID only authenticates; the master password still derives the key that decrypts the vault, so a Pocket ID session alone opens nothing. `SSO_ONLY` is true, so email and master password login is refused and cannot bypass Pocket ID or its `admins` restriction. `SSO_ALLOW_UNKNOWN_EMAIL_VERIFICATION` stays unset, so an SSO login never takes over an existing account whose email Pocket ID does not report as verified.
- `SIGNUPS_ALLOWED` is false from the first deploy. Vaultwarden gates SSO registration with `SSO_SIGNUPS_ALLOWED` instead, which stays at its default of true, so the owner's first account is created through Pocket ID and the `admins` restriction is the only path to a new account.
- `ADMIN_TOKEN` is unset, which keeps the `/admin` panel off. Configuration comes from the HelmRelease and the `vaultwarden` Secret only.
- NetworkPolicies allow ingress from Traefik and egress to DNS, Postgres and the Traefik VIP for the Pocket ID issuer only. Icon downloads are disabled to match, and no SMTP or push relay is configured.

## Consequences

- The vault is restored by the same drills as Pocket ID and Paperless, and losing a node loses no vault data.
- Away from home the clients reach the vault over the tailnet only. The browser extension and the iPhone app keep an offline copy of the vault, so a cluster or Pocket ID outage blocks sign-in, edits and new devices, not reading. With `SSO_ONLY` on there is no other way to sign in; a git change that sets `SSO_ONLY` to false re-enables master password login until Pocket ID is back.
- Without SMTP there is no email verification, invitation or emergency access mail, and without the push relay the iPhone app picks up changes on its next sync rather than at once.

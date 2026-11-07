---
status: accepted
date: 2026-11-07
---

# 0007. Share one CloudNativePG cluster with per-app databases

## Context

Pocket ID, Paperless, Open WebUI and LiteLLM each need Postgres. A cluster per app would multiply the replicas, backups and memory on three small nodes, while one shared database with one shared login would let any app read every other app's data.

## Decision

- One CloudNativePG cluster, `postgres` in the `postgres` namespace, runs three instances with required anti-affinity across the nodes. Writes commit once any one standby confirms them, with durability set to preferred, so the primary keeps accepting writes when both standbys are gone.
- Each app owns its role and database. The app's own `db/` folder, `kubernetes/apps/<app>/db/` for apps and `kubernetes/infrastructure/controllers/pocket-id/db/` for Pocket ID, holds a `DatabaseRole` and a `Database` for the shared cluster, and the role's password comes from the app's `pg-<app>` Secret in `bedrock-secrets`. The matching Kustomization (`<app>-db`, or `cluster-pocket-id-db`) reports Ready only once CNPG has applied both, and the app waits on it.
- Access to port 5432 is granted per namespace by the `bedrock.io/postgres-client` label ([0008](0008-deny-network-traffic-by-default.md)).
- Backups use the barman-cloud plugin, installed from its upstream Helm chart, with the in-tree `barmanObjectStore` gone. WAL is archived continuously and a base backup runs daily at 02:30 to the `bedrock-postgres` bucket in R2, kept for 30 days ([0012](0012-back-up-off-site-to-cloudflare-r2-and-test-restores.md)).
- `just psql`, `just dump` and `just restore` work per app against the app's own database.

## Consequences

- Adding a database is two small manifests and one Secret, with no change to the cluster definition.
- One cluster is one failure domain: a fault in Postgres affects every app at once.
- Removing an app does not drop its role, and dropping a database needs its reclaim policy set to delete in one reconcile before the resource is removed in the next.
- The Postgres backups in R2 are not encrypted client-side. That is an accepted risk, scoped to the bucket's credentials.

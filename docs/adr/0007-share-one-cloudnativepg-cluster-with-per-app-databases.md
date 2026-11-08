---
status: accepted
date: 2026-11-07
---

# 0007. Share one CloudNativePG cluster with per-app databases

## Context

Pocket ID, Paperless, Open WebUI and LiteLLM each need Postgres, and between them it holds the OCR text and metadata of every Paperless document, every Open WebUI chat, the Pocket ID users, sessions and OIDC clients, and LiteLLM's keys and spend logs. A cluster per app would multiply the replicas, backups and memory on three small nodes, while one shared database with one shared login would let any app read every other app's data.

## Decision

- One CloudNativePG cluster, `postgres` in the `postgres` namespace, runs three instances with required anti-affinity across the nodes. Writes commit once any one standby confirms them, with durability set to preferred, so the primary keeps accepting writes when both standbys are gone.
- Each app owns its role and database. The app's own `db/` folder, `kubernetes/apps/<app>/db/` for apps and `kubernetes/infrastructure/controllers/pocket-id/db/` for Pocket ID, holds a `DatabaseRole` and a `Database` for the shared cluster, and the role's password comes from the app's `pg-<app>` Secret in `bedrock-secrets`. The matching Kustomization (`<app>-db`, or `cluster-pocket-id-db`) reports Ready only once CNPG has applied both, and the app waits on it.
- Access to port 5432 is granted by the `bedrock.io/postgres-client` label on both the client namespace and each client pod ([0008](0008-deny-network-traffic-by-default.md)).
- Every database is named after its owner role, so `pg_hba` admits a login over TLS with `scram-sha-256` only to the database of the same name (`hostssl sameuser`) and rejects everything else. CloudNativePG writes its own rules for local peer access, `streaming_replica` certificate authentication and the pooler before the user rules, so replication and the operator are unaffected. `enableSuperuserAccess` is false: `postgres` has no password, and `just psql`, `just dump` and `just restore` reach it over the local socket through `kubectl exec`. `scripts/check-manifests.sh` fails when a Cluster allows superuser access or its `pg_hba` does not end in the reject.
- The initdb `app` database and role stay. CloudNativePG 1.30 always defaults `bootstrap.initdb` to them: the instance manager on the primary resets the `app` password from `postgres-app` and fails its reconcile loop when the role is missing, and the default metrics queries, which feed the replication alerts, connect to `app`. `sameuser` confines the role to its own empty database.
- Connections are encrypted, but no app verifies the server certificate yet: Pocket ID, Paperless, Open WebUI and LiteLLM all connect without `sslmode=verify-full`. The CNPG CA rotates with the cluster's 90-day certificates, so it cannot be pinned in git.
- The instances are declared on `longhorn-encrypted`. A storage class change applies only to PVCs CloudNativePG creates afterwards, so the running instances stay on `longhorn` until they are recovered onto the new class, and each new instance volume runs `just luks-discards` once ([0006](0006-store-volumes-on-longhorn.md)).
- Backups use the barman-cloud plugin, installed from its upstream Helm chart, with the in-tree `barmanObjectStore` gone. WAL is archived continuously and a base backup runs daily at 02:30 to the `bedrock-postgres` bucket in R2, kept for 30 days ([0012](0012-back-up-off-site-to-cloudflare-r2-and-test-restores.md)).
- `just psql`, `just dump` and `just restore` work per app against the app's own database.

## Consequences

- Adding a database is two small manifests and one Secret, with no change to the cluster definition.
- One cluster is one failure domain: a fault in Postgres affects every app at once.
- An app's role reaches only its own database, and a pod outside the client label cannot open a connection at all.
- Removing an app does not drop its role, and dropping a database needs its reclaim policy set to delete in one reconcile before the resource is removed in the next.
- The Postgres backups in R2 are not encrypted client-side. That is an accepted risk, scoped to the bucket's credentials.

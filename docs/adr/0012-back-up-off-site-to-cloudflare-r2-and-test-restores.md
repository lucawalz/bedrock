---
status: accepted
date: 2026-11-07
---

# 0012. Back up off-site to Cloudflare R2 and test restores

## Context

Longhorn replicas and Postgres standbys protect against a lost node, not against a lost house, a bad migration or a mistaken delete. The cluster had no off-site copy before the rebuild. A backup is known to work only once it has been restored.

## Decision

- Off-site copies go to Cloudflare R2, one bucket per mechanism, each written with its own bucket-scoped token: `bedrock-postgres` for continuous WAL archiving and daily base backups kept 30 days ([0007](0007-share-one-cloudnativepg-cluster-with-per-app-databases.md)), `bedrock-longhorn` for the nightly `offsite-backup` job kept 14 deep ([0006](0006-store-volumes-on-longhorn.md)), and `bedrock-etcd` for the K3s snapshots taken every 12 hours ([0003](0003-run-k3s-as-one-server-and-two-agents-on-the-tailnet.md)).
- R2 stays the target once the data outgrows the 10 GB free tier, and the overage is paid. A cheaper provider would save little against the cost and risk of a migration.
- Only data that cannot be refetched is backed up. Ollama models and the zot cache never are.
- Paperless and Open WebUI backups are ciphertext because their volumes are LUKS-encrypted. Postgres backups are not encrypted client-side, which is an accepted risk.
- `just restore-test` runs the drills: a point-in-time clone of Postgres from R2 compared by row count on tables that change only on upgrades, a restore of the Paperless data backup that must refuse a wrong key and unlock with the real one, and a check that the newest etcd snapshot in R2 is less than 13 hours old. Each drill removes everything it created.
- The drills run monthly and before major upgrades, and the whole cluster is rebuilt from git twice a year.
- Alerts fire on stale or missing Postgres, Longhorn and etcd backups.

## Consequences

- Every stateful component has a copy outside the house and a tested path back.
- The keys that make the copies usable (the age key, the cluster root CA and the Longhorn key) are held on an encrypted offline medium, not in R2 ([0004](0004-keep-a-stable-cluster-ca-under-an-offline-root.md)).
- The R2 bill grows with the data, with a Cloudflare budget alert as the guard.

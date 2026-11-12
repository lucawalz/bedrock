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
- Only data that cannot be refetched is backed up. Ollama models, the Open WebUI model cache and the zot cache never are; the Open WebUI cache lives in an `emptyDir` refetched on start.
- Paperless and Open WebUI backups are ciphertext because their volumes are LUKS-encrypted.
- Postgres base backups and WAL go to R2 in plaintext. Server-side encryption with customer keys (SSE-C in plugin-barman-cloud 0.16.0) waits on the Renovate update of the plugin; it protects only against a leak on the R2 side, because the key lives in the cluster next to the data.
- A nightly `postgres-dump` CronJob writes a logical dump of every app database that only an offline key can read: `pg_dump --format=custom` as the `dumper` role, piped through `gpg --encrypt` to an OpenPGP key whose private half exists only on the offline medium, and uploaded to `bedrock-postgres/dumps/<database>/<UTC time>.gpg`, named like `2026-11-10T033000Z.gpg` so that a rerun on the same day adds an object instead of overwriting one. The newest 30 dumps are kept per database, pruned by the same job. The job imports the public key from a ConfigMap and refuses to run unless its fingerprint matches the one pinned in the CronJob. Each dump is encrypted into a file in the pod's `/tmp` and uploaded only once `pg_dump` and gpg have both exited 0, so a failed dump leaves no object behind to remove; it fails the Job, which raises `KubeJobFailed`.
- R2 bucket lock rules make recent objects undeletable and unoverwritable even with the bucket's own token, but a lock also refuses the overwrite of a locked key, and a rule matches by key prefix, so a rule goes only where every key under it is written once. Two prefixes qualify: `bedrock-postgres/dumps/`, locked 14 days against the 30 days the dump job keeps, and `bedrock-etcd/etcd-snapshots/`, locked 2 days against the 60 hours after which K3s prunes a snapshot (5 kept, every 12 hours). Each lock stays shorter than its consumer's pruning age, so no prune is refused.
- Longhorn and barman-cloud get no lock, because both rewrite keys they have just written (Longhorn's backup config, barman's `backup.info` and a WAL archived a second time after a crash), so a lock would fail or stall their backups. Their blocks and WAL restore nothing without those configs and base backups.
- A monthly offline copy covers what the locks cannot: `just offline-backup <mountpoint>` copies the newest dump of every database, the newest etcd snapshot and, per Longhorn volume, `volume.cfg`, the newest backup config and exactly the blocks it lists, keeping the bucket layout so the copy can be uploaded back to a bucket and restored. It reads R2 with one Object Read only token per bucket, kept only in `/Volumes/bedrock-keys/bedrock/rclone/offline-backup.conf` on the key stick, and refuses to start when the target is not a mounted, writable volume, the token config is missing or the copy plus 10 percent does not fit.
- The dumps use gpg rather than age because the pinned CloudNativePG image already carries gpg, a `pg_dump` matching the server and boto3 for the upload. age ships in no maintained image, so it would have needed a separate image or a downloaded binary, each a new supply chain with read access to every database.
- `just restore-test` runs the drills: a point-in-time clone of Postgres from R2 compared by row count on tables that change only on upgrades, a restore of the newest encrypted dumps into a scratch database on the primary, decrypted on the Mac from the offline medium and compared the same way, a restore of the Paperless data backup that must refuse a wrong key and unlock with the real one, and a check that the newest etcd snapshot in R2 is less than 13 hours old. Each drill removes everything it created.
- The drills run monthly and before major upgrades, and the whole cluster is rebuilt from git twice a year.
- Alerts fire on stale or missing Postgres, Longhorn and etcd backups, and on WAL archiving that keeps failing (`CNPGWALArchivingFailing`), which would otherwise surface only once the instance volume fills.

## Consequences

- Every stateful component has a copy outside the house and a tested path back.
- The keys that make the copies usable (the age key, the Postgres dump key, the cluster root CA and the Longhorn key) are held on an encrypted offline medium, not in R2 ([0004](0004-keep-a-stable-cluster-ca-under-an-offline-root.md)).
- The R2 bill grows with the data, with a Cloudflare budget alert as the guard.
- A stolen bucket token can still erase the Postgres base backups and WAL, every Longhorn backup and any dump or etcd snapshot older than its lock. The dumps from the last 14 days, the etcd snapshots from the last 2 days and the latest offline copy survive it.
- The locks stop only bucket-scoped Object tokens. Any credential with R2 admin rights, such as the `wrangler login` session on the Mac or an Admin Read & Write token, can drop a rule with `wrangler r2 bucket lock remove` and then erase everything in R2; only the offline copy survives that. The wrangler session is therefore logged out with `wrangler logout` once the lock rules are in place.
- Deleting objects under a locked prefix, for example the pre-rebuild objects, waits until each lock has expired.

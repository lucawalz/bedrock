# Disaster recovery

How the cluster is rebuilt from git, how data comes back from Cloudflare R2, how recovery is rehearsed, and what is still a gap.

Everything declared in this repository and in `bedrock-secrets` is reconciled back by Flux. A rebuild needs three things the repositories cannot hold (the recovery keys below), and data comes back from the off-site backups in R2.

## What survives what

| Scenario | Recoverable | Mechanism |
| --- | --- | --- |
| One disk or one node lost | Yes | Longhorn keeps three replicas of every volume except the two disposable ones, workloads reschedule, and a Postgres standby takes over. The running Postgres instances are still on unencrypted three-replica `longhorn` volumes; once they are recovered onto the declared `longhorn-encrypted-local`, a lost node's Postgres instance needs the manual step in [Losing a node that hosts Postgres](#losing-a-node-that-hosts-postgres) |
| Anything declared in git | Yes | Flux reconciles it back ([ADR 0001](adr/0001-reconcile-the-cluster-from-git-with-the-flux-operator.md)) |
| Any cluster Secret | Yes, given the age key | SOPS ciphertext in the private `bedrock-secrets` repository ([ADR 0005](adr/0005-keep-host-secrets-in-agenix-and-cluster-secrets-in-sops.md)) |
| A Postgres logical fault, a bad migration, a dropped table | Yes, to any point in the last 30 days | Continuous WAL archive and daily base backups in R2 ([ADR 0007](adr/0007-share-one-cloudnativepg-cluster-with-per-app-databases.md)) |
| A volume deleted or corrupted | Yes for volumes with jobs, from the last nightly snapshot (7 kept) or backup (14 kept) | Longhorn `snapshot` at 03:30 and `offsite-backup` at 05:00 ([ADR 0006](adr/0006-store-volumes-on-longhorn.md)) |
| control-plane-1's datastore lost | Yes, to the last 12-hourly snapshot | etcd snapshots on the node and in R2 ([ADR 0003](adr/0003-run-k3s-as-one-server-and-two-agents-on-the-tailnet.md)) |
| Loss of the building | Yes for Postgres, Paperless and Open WebUI, given new hardware and the offline keys | Rebuild from git, data from R2; volumes without an off-site backup (Grafana, paperless-gpt, metrics, logs) come back empty |
| Loss of the Longhorn volume key | No for Paperless and Open WebUI data | Encrypted volumes and their backups are LUKS ciphertext |

## Recovery seeds

The age keys, the K3s root CA and the Longhorn volume encryption key are the three keys a rebuild cannot recreate. They are kept together on an encrypted offline medium (the APFS-encrypted `bedrock-keys` USB stick). The K3s root CA key lives only there; the other two also have a copy on the admin Mac ([ADR 0004](adr/0004-keep-a-stable-cluster-ca-under-an-offline-root.md)).

| Seed | Where it lives | Why it matters |
| --- | --- | --- |
| SOPS age key (current) | `~/.config/sops/age/keys.txt` on the Mac, `age-keys.txt` on the offline medium, and the `sops-age` Secret in `flux-system` | Decrypts every file in `bedrock-secrets`, including the deploy key for that repository. `just bootstrap` reads it from `/Volumes/bedrock-keys/bedrock/age-keys.txt` unless `SOPS_AGE_KEY_FILE` says otherwise |
| SOPS age key (new, 2026-11) | `age-cluster-2026-11.txt` on the offline medium only | A recipient on every SOPS file next to the current key. It replaces the current key as the `sops-age` Secret at the Phase 4 rebuild |
| SOPS age identity (Secure Enclave) | Secure Enclave of the Mac, created with `age-plugin-se`; only the public recipient is in git | A recipient on every SOPS file, so the Mac edits secrets without a key file. It cannot be copied off the Mac |
| K3s root CA | `root-ca.pem` and `root-ca.key` in `/Volumes/bedrock-keys/bedrock/k3s-root-ca/` on the offline medium only; `scripts/generate-cluster-ca.sh` reads them there, or from `BEDROCK_ROOT_CA_DIR` | Signs the cluster CA in `secrets/k3s-ca.age`; the agent token pins the root. Without it, the next CA re-issue needs a new root and a re-pinned token |
| Longhorn volume encryption key | `CRYPTO_KEY_VALUE` of the `longhorn-crypto` Secret, from `clusters/home/platform/longhorn-crypto.sops.yaml` in `bedrock-secrets`, and the offline medium | Opens every `longhorn-encrypted` volume. Losing it makes the encrypted Paperless and Open WebUI backups unrecoverable |
| The two repositories | GitHub: `bedrock` and the private `bedrock-secrets` | Flux syncs from them |
| Admin host key | Secure Enclave key `estate-root` on the Mac, in `hosts/common/estate-root.pub`, read by `hosts/common/users.nix` and `hosts/router-installer.nix` | Root login on every host. It cannot be copied off the Mac |
| Break-glass host key | `/Volumes/bedrock-keys/bedrock/ssh/estate-breakglass` on the offline medium only, passphrase-protected | Root login on every host when the Secure Enclave keys are unavailable |
| Break-glass kubeconfig | `/Volumes/bedrock-keys/bedrock/kubeconfig-admin.yaml` on the offline medium only, written by `just kubeconfig-admin` | A `system:masters` client certificate that does not depend on Pocket ID. `just bootstrap` runs with it, and it is the only cluster access while Pocket ID is down. The Mac keeps only the Pocket ID context `bedrock`. Recreated from control-plane-1 whenever lost, as long as root SSH works |
| Admin agenix key | `~/.ssh/id_ed25519` on the Mac | A recipient on every agenix secret; needed to re-key host secrets when a host key is lost. It no longer logs in to any host. Security keys cannot decrypt age files, so this key stays until agenix gets another recipient |
| Host SSH keys | `/etc/ssh/ssh_host_ed25519_key` on each host | agenix secrets are encrypted to them. A reinstalled host gets new keys and cannot decrypt until the secrets are re-keyed |

The K3s server token (`secrets/k3s-token.age`) and the etcd R2 credentials (`secrets/etcd-s3-credentials.age`) are in git as agenix files. The R2 credentials for Postgres and Longhorn, the Cloudflare tokens and every app secret are in `bedrock-secrets`. The accounts behind them (GitHub, Cloudflare, Tailscale, Anthropic) live outside both repositories.

## Off-site backups

| Data | Bucket | Schedule and retention | Encryption | Alerts |
| --- | --- | --- | --- | --- |
| Postgres (all app databases: Paperless document OCR text and metadata, Open WebUI chats, Pocket ID users and OIDC clients, LiteLLM keys and spend) | `bedrock-postgres`, under `postgres/` | WAL continuously (`archive_timeout` 5 min), base backup daily at 02:30, 30 days | None client-side, an accepted risk ([ADR 0012](adr/0012-back-up-off-site-to-cloudflare-r2-and-test-restores.md)) | `CNPGBackupStale`, `CNPGBackupNotConfigured` |
| Longhorn volumes with the `offsite-backup` label: the four Paperless volumes and Open WebUI | `bedrock-longhorn` | Daily at 05:00, 14 kept | All of them are LUKS, so their backups are ciphertext | `LonghornBackupStale`, `LonghornBackupNeverCompleted` |
| etcd | `bedrock-etcd`, under `etcd-snapshots/` | Every 12 hours, 5 kept, also on control-plane-1's disk | None client-side, an accepted risk ([ADR 0004](adr/0004-keep-a-stable-cluster-ca-under-an-offline-root.md)); Secrets are encrypted by K3s and the bootstrap data needs the server token | `EtcdSnapshotTooOld` |

### Locks and the offline copy

R2 bucket lock rules refuse every delete and overwrite of a recent object sent with a bucket-scoped Object token; a refused single delete returns HTTP 409 `ObjectLockedByBucketPolicy`. They do not stop a credential with R2 admin rights, such as a `wrangler login` session or an Admin Read & Write token, which can drop the rule with `wrangler r2 bucket lock remove` and then delete anything, so the wrangler session stays logged out (`wrangler logout`) outside lock maintenance. They cover only prefixes whose keys are written once ([ADR 0012](adr/0012-back-up-off-site-to-cloudflare-r2-and-test-restores.md)):

| Bucket | Prefix | Locked for | Pruned by its consumer after |
| --- | --- | --- | --- |
| `bedrock-postgres` | `dumps/` | 14 days | 30 dumps per database, daily, so about 30 days |
| `bedrock-etcd` | `etcd-snapshots/` | 2 days | 5 snapshots every 12 hours, so 60 hours |

The barman archive under `bedrock-postgres/postgres/` and everything in `bedrock-longhorn` stay unlocked, because barman-cloud and Longhorn rewrite keys they have just written. No restore below deletes or overwrites a key under a locked prefix: the dumps and etcd snapshots are only read, and a recovered Postgres cluster archives under a new server name. Deleting old objects under a locked prefix, for example after a rebuild, waits until the lock has expired. `wrangler r2 object delete` prints `Delete complete` even when R2 refuses the delete of a locked object, so a delete is confirmed by reading the object back with `wrangler r2 object get` or through the S3 API, which returns the refusal. `wrangler r2 bucket lock list <bucket>` shows the rules, and `wrangler r2 bucket lock remove <bucket> --name <rule>` drops one.

Once a month, `just offline-backup <mountpoint>` copies the newest dumps, etcd snapshot and Longhorn backups to `<mountpoint>/bedrock-offline/<UTC time>/<bucket>/`, in the bucket layout ([ADR 0012](adr/0012-back-up-off-site-to-cloudflare-r2-and-test-restores.md)). The etcd snapshot is plaintext apart from Secrets, so the target is an encrypted volume. With one offline medium (owner decision 2026-11-09), the copy goes onto the `bedrock-keys` stick next to the keys: `just offline-backup /Volumes/bedrock-keys`. Losing the stick loses the keys and the copy together, and whoever opens it holds both. Older copies are deleted when the next one no longer fits. To restore from it, upload a bucket folder with `rclone copy` into a new, empty bucket and point the consumer at that bucket; the copied dumps decrypt with the same key, and the Longhorn backups are LUKS ciphertext that needs `longhorn-crypto`. A copied `volume.cfg` may name a newer backup than the one copied when a backup finished during the copy, so the restore names the backup explicitly, from the copied `backups/backup_<name>.cfg`.

Ollama models and the zot cache are refetched, never backed up. The Postgres instances carry Longhorn snapshots but no Longhorn backup, since barman-cloud covers them.

## The measured rebuild

On 2026-11-06 the K3s state on all three nodes was wiped and the cluster was rebuilt from git. NixOS, the agenix secrets, the Tailscale identities and the host keys stayed; the R2 buckets started empty, so the run restored no data. Times are CET.

| Time | Event |
| --- | --- |
| 11:36 | Wipe started |
| 11:44 | Nodes rebooted onto the new generation |
| 12:30 | All three nodes Ready on the new cluster CA, after the token and CA pin defect was fixed |
| 12:33 | `just bootstrap` |
| 12:40 | Flux syncing, after the CoreDNS cold-start deadlock was fixed |
| 13:56 | 42 of 42 Kustomizations and 33 of 33 HelmReleases Ready |

End to end the rebuild took about 2 h 20 min. Bootstrap to full convergence took about 1 h 25 min, dominated by image pulls through the empty zot pull-through cache. The run hit four defects, each fixed in git while it ran:

| Symptom | Cause | Fix |
| --- | --- | --- |
| Agents refuse to join: `x509: certificate signed by unknown authority` | The agent token pins the CA hash, and the wiped server generated a new CA | A stable cluster CA under an offline root, installed before the first K3s start ([ADR 0004](adr/0004-keep-a-stable-cluster-ca-under-an-offline-root.md)) |
| The GitRepository cannot resolve `github.com` | K3s runs with `--disable=coredns` and CoreDNS is Flux-managed, so a cold cluster has no DNS to fetch the repository that installs it | `just bootstrap` applies CoreDNS before Flux |
| The `paperless-gpt-access` Job fails with `relation "auth_group" does not exist` | It ran before paperless-ngx had migrated its database | The Job moved into its own Kustomization that depends on `paperless` |
| HelmReleases stalled with `MissingRollbackTarget` | An install timed out on the cold cache, the retry ran as an upgrade, and the upgrade rollback had no successful revision | `RetryOnFailure` for installs and upgrades on every HelmRelease, enforced in CI |

A fifth defect appeared after convergence: the first forced OCR OOMKilled paperless-ngx, because the pod sees six cores under a two-CPU limit and started about six OCR threads. `PAPERLESS_THREADS_PER_WORKER` now caps it.

## Rebuilding the cluster from git

This is the procedure as run on 2026-11-06, with the fixes in place. It wipes the K3s state and keeps the operating systems. A reinstall of the operating system is covered in [Reinstalling a host](#reinstalling-a-host).

### Before the wipe

1. Confirm the seeds: `sops -d` of a file in `bedrock-secrets` succeeds with the age key, and on control-plane-1 both `/run/agenix/k3s-token` and `/run/agenix/k3s-ca` exist, so the cluster CA in `secrets/k3s-ca.age` decrypts there.
2. Run `nix flake check` and every `scripts/check-*.sh`.
3. If `main` carries changes the running cluster has not applied, freeze the cluster before pushing, so it never applies them or writes into R2: annotate the `FluxInstance` with `fluxcd.controlplane.io/reconcile: disabled`, then `flux suspend source git flux-system` and suspend every Kustomization and HelmRelease. `flux suspend` takes no `-A`, so loop over the namespaces with `--all -n <namespace>`.
4. Decide what happens to the data: a rebuild that discards it, or one that keeps it and follows [Restoring data from R2](#restoring-data-from-r2). The first step of [Bootstrap and converge](#bootstrap-and-converge) depends on the choice.

### Wipe and rebuild the nodes

1. `just deploy-nodes` is the normal path for routine rebuilds; this runbook keeps its own jump config for cold rebuilds, when the recipe cannot run. Rebuild the router first if its configuration changed, through control-plane-1's own tailnet address: a router switch restarts tailscaled and cuts any session through the Pi's subnet route. An SSH config file for the jump:

   ```
   Host cp1-direct
     HostName 100.105.211.67
     HostKeyAlias 10.20.0.10
     User root
     IdentityFile <repository>/hosts/common/estate-root.pub
     IdentityAgent ~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh

   Host 10.20.0.1 10.20.0.10
     ProxyJump cp1-direct
     IdentityFile <repository>/hosts/common/estate-root.pub
     IdentityAgent ~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh
   ```

   ```
   NIX_SSHOPTS="-F <config file>" nixos-rebuild switch --flake .#router --target-host root@10.20.0.1 --build-host root@10.20.0.10
   ```

   `100.105.211.67` is control-plane-1's tailnet address from `lib/inventory.nix`. `NIX_SSHOPTS` is split on spaces, so the jump goes in a config file rather than an inline `ProxyCommand`.
2. Build and stage the new generation on every node with `nixos-rebuild boot` (see [Changing a host](../README.md#changing-a-host) for `--build-host`), so each node comes up once, fresh, on the new generation.
3. On worker-2, then worker-1, then control-plane-1: `systemctl stop k3s` and `k3s-killall.sh`, then confirm that `findmnt` lists nothing under `/var/lib/kubelet` or `/var/lib/longhorn`. A Longhorn CSI mount whose engine lived on an already stopped node can hang the forced unmount; `umount -l` clears it.
4. Remove the state and purge the iSCSI node records in the same command as the reboot, since stale records break the next attach in either direction. Reboot control-plane-1 first:

   ```
   rm -rf /var/lib/rancher/k3s /etc/rancher/k3s /var/lib/longhorn /var/lib/kubelet /etc/iscsi/nodes && systemctl reboot
   ```

   NixOS recreates the files it manages under `/etc/rancher/k3s` on boot.
5. control-plane-1 starts with `clusterInit`. The `k3s-ca` unit unpacks `secrets/k3s-ca.age` into `/var/lib/rancher/k3s/server/tls` because no `server-ca.crt` exists, so the server comes back with the same CA and the agents join with the unchanged token. `KUBECONFIG=/Volumes/bedrock-keys/bedrock/kubeconfig-admin.yaml kubectl get nodes` shows three Ready nodes once `just kubeconfig-admin` has written the new admin certificate.

### Bootstrap and converge

1. After the wipe and before `just bootstrap`, check the R2 targets with each bucket's own credentials. Flux creates the `postgres` Cluster with `initdb`, and its archive check fails if `s3://bedrock-postgres/postgres/` already holds WAL from an earlier cluster; a BackupVolume left in `bedrock-longhorn` re-syncs into the new cluster. For a rebuild that discards data, delete what is there once the owner confirms. For a rebuild that keeps data, leave both and restore as in [Restoring data from R2](#restoring-data-from-r2).
2. Run `just bootstrap` ([README](../README.md#flux)). It writes the break-glass kubeconfig to the stick and runs every step with it, applies CoreDNS, installs the flux-operator chart, applies the `FluxInstance`, creates `sops-age` and the sync deploy key, and waits for the `FluxInstance`.
3. Let `just bootstrap` register the printed public key as the read-only deploy key `flux-home-cluster` (or add it by hand with Allow write access unchecked), and delete the previous cluster's key. Nothing in the cluster writes to git.
4. Open `https://id.syslabs.dev/setup` as soon as Pocket ID runs and register the owner passkey; the claim page is open to the home LAN until then. In the Pocket ID admin UI, mark the owner email as verified. oauth2-proxy rejects an unverified email, and every forward-auth login answers 500 until this is done ([ADR 0010](adr/0010-sign-in-through-pocket-id-and-oauth2-proxy.md)). Then run `just kubeconfig` and `kubectl --context bedrock get nodes`; the passkey login proves the Pocket ID path before the stick goes back in the drawer.
5. Check that the public DNS records for `chat.syslabs.dev` and `lucawalz.dev` still point at the tunnel. They are made by hand in the Cloudflare dashboard.
6. Watch `flux get kustomizations -A` and `flux get helmreleases -A` until everything is Ready. Any stall gets a root-cause fix in git, never a live patch.

### Cold-start behaviour to expect

- Pods with multi-gigabyte images (Ollama, Open WebUI) sit in `ImagePullBackOff` for a while. zot fetches an image fully before it answers the manifest request, the containerd pull deadline cancels the request first, and containerd does not fall back to the upstream registry. They recover once zot has the image.
- The `bedrock-secrets` GitRepository can wait up to its 10 minute interval before its deploy key Secret exists. `flux reconcile source git bedrock-secrets -n flux-system` shortens the wait.
- The `cluster-cnpg-db` Kustomization can time out once while the Postgres instances run `initdb`, and pass on the retry.
- The Jobs that rebuild state from git run once Flux reaches them: `cluster-pocket-id-clients` upserts the OIDC clients, `litellm-keys` recreates the paperless-gpt virtual key, `paperless-gpt-access` creates the Paperless service user and its workflow, and `cluster-grafana-public-dashboard` recreates the bar panel's public share. Each Job is deleted an hour after it finishes and re-created on the next 10 minute reconcile, so a rotated client secret or a share lost with an emptied Grafana database comes back within about 70 minutes.
- The `paperless-taxonomy` CronJob recreates the document types, tags, custom fields, correspondents and mail rules every 15 minutes, and paperless-gpt waits in its init container until they exist.

### Verify

- `kubectl get nodes` shows three Ready nodes and `kubectl get certificates -A` shows every certificate Ready.
- The `postgres` Cluster reports `ContinuousArchiving=True`, `just backup` completes, and objects appear in `bedrock-postgres`.
- The Longhorn BackupTarget is available, and `k3s etcd-snapshot ls` on control-plane-1 lists an `s3://bedrock-etcd` entry after the first scheduled snapshot.
- `scripts/check-alert-selectors.sh` passes against the new Prometheus ([alert selector audit](alert-selector-audit.md)).
- Forward-auth hosts land on Pocket ID, and the bar panel shows the dashboard with a live deadman label.
- `just restore-test` passes once the first backups exist.

## Restoring data from R2

The drills below restore each backup into a scratch object and compare it with production. Restoring into production has not been rehearsed, so the outlines here are untested.

### Postgres

`just restore-test postgres` creates a one-instance `postgres-restore-test` Cluster that bootstraps by `recovery` from the `postgres-backup` ObjectStore (server name `postgres`) through the barman-cloud plugin, which is the manifest to copy. To bring the production cluster back after a rebuild, change `bootstrap` in `kubernetes/infrastructure/configs/cnpg/cnpg-cluster.yaml` from `initdb` to the same `recovery` source before Flux first creates the Cluster, and point its WAL archiver at a new server name so it does not write into the archive it reads from. The Cluster declares `longhorn-encrypted-local`, so the recovered instances land on LUKS volumes with one strict-local replica each; run `just luks-discards postgres/postgres-<n>` for each instance PVC once it is attached, or `filesystem-trim` frees nothing. For a single app, `just dump` and `just restore` move one database without touching the others.

If the barman archive is unusable, the nightly logical dumps in `bedrock-postgres/dumps/<database>/<UTC time>.gpg` are the fallback; the newest key sorts last. They are encrypted to the OpenPGP key on the offline medium: `gpg --homedir /Volumes/bedrock-keys/bedrock/gnupg-postgres-dumps --decrypt` reads one on stdin and writes the `pg_dump` custom-format archive to stdout, which `kubectl exec -i` into the primary can feed straight to `pg_restore`, so the plaintext never touches the disk.

### Longhorn volumes

Longhorn lists the backups in `bedrock-longhorn` once its BackupTarget polls the bucket. A volume restored from a backup must exist before the app's claim binds to a fresh empty volume, so the app's Kustomization is suspended, the restored volume is bound to the claim name the app expects, and the Kustomization is resumed. `just restore-test longhorn` shows the restore and the binding as a static PersistentVolume. Encrypted volumes need the `longhorn-crypto` Secret in place first; `bedrock-secrets` provides it, or the offline copy if the repository is gone.

### etcd

A snapshot restores the whole Kubernetes API state. It is the right tool only when the API holds state that Flux cannot reconcile back. The server token governs the restore: a snapshot restored under a different token gives a cluster that starts and returns ciphertext for every Secret, without an error. On control-plane-1, as root, with the token and the S3 credentials that the `k3s` unit reads from agenix:

```
systemctl stop k3s
set -a; . /run/agenix/etcd-s3-credentials; set +a
k3s server --cluster-reset --secrets-encryption --token-file=/run/agenix/k3s-token \
  --etcd-s3 --etcd-s3-bucket=bedrock-etcd --etcd-s3-folder=etcd-snapshots \
  --etcd-s3-endpoint=<account id>.r2.cloudflarestorage.com --etcd-s3-region=auto \
  --cluster-reset-restore-path=<snapshot name>
```

`--secrets-encryption` is needed here too, or the API server cannot read what it restored. Then start K3s normally and restart the agents, since `--cluster-reset` drops every peer. Reading `flux-system/sops-age` and getting decodable data proves that the token, the encryption config and the snapshot agree. This restore has never been run. Rehearsing it needs an isolated host with no route to VLAN 20, started with `--disable-agent`, because a restored snapshot carries the live MetalLB pools, Flux sources and issuers. Treat that host as holding production secrets and destroy it afterwards.

## Losing a node that hosts Postgres

The Cluster declares `longhorn-encrypted-local` for its instance volumes: LUKS with one strict-local replica, bound to the node of the first attach. A storage class change reaches only PVCs that CloudNativePG creates afterwards, so the running instances stay on unencrypted three-replica `longhorn` volumes, which reschedule like any other, until they are recovered onto the new class ([ADR 0007](adr/0007-share-one-cloudnativepg-cluster-with-per-app-databases.md)). On the declared class, when that node or its disk is lost for good, the instance's PVC stays pinned to it, CloudNativePG does not delete a PVC on its own, and the pod stays Pending. The required anti-affinity across three nodes also leaves no other node for a fourth instance. If the node returns with its disk intact, the pod resumes by itself. Otherwise replacement is manual:

```
kubectl cnpg destroy postgres <n>
just luks-discards postgres/postgres-<m>
```

`kubectl cnpg destroy` removes the instance pod and its PVCs ([CloudNativePG kubectl plugin](https://cloudnative-pg.io/docs/1.30/kubectl-plugin)); the plugin is a krew install, not part of the dev shell. CloudNativePG then creates a new instance with a new number, clones it from a sibling and the new PVC is the one to pass to `just luks-discards` once it is attached. Without the plugin, deleting the instance's pod and PVCs with `kubectl delete` has the same effect (not verified against the CloudNativePG docs). If the lost instance was the primary, a standby has been promoted already. While one instance is missing, the cluster keeps `dataDurability: preferred` and serves writes.

## Reinstalling a host

The rebuild above keeps the operating systems. A full reinstall has not been rehearsed:

1. Router first. Flash the `router-installer` SD image, which is a bare Pi with SSH and the `estate-root` key and no network services, then push `.#router` with `--build-host` set to the Pi itself. Until that finishes there is no VLAN 20.
   A re-enrolled router needs a fresh single-use auth key tagged `tag:router`, re-encrypted into `secrets/tailscale-authkey.age`; the old key was minted for `tag:cluster`.
2. Nodes: install NixOS (disko lays out the disk) and push the node configuration with `--build-host` set to the target. control-plane-1's `hardware-configuration.nix` and `default.nix` pin filesystem UUIDs that change with a new disk and must be updated.
3. A new host key cannot decrypt its agenix secrets. Re-key as in [Secret recovery](#secret-recovery) before the switch, and give the host a new single-use Tailscale auth key pre-tagged `tag:cluster`.
4. Continue with the bootstrap above.
5. A wiped node comes back with empty disks, so its Postgres instance volume is gone. Replace that instance as in [Losing a node that hosts Postgres](#losing-a-node-that-hosts-postgres); the pod does not recover on its own.

## Restore drills

`just restore-test` runs four drills and removes everything it creates. `all` runs `dumps` last, because only that drill needs the key stick:

- `postgres`: a clone from R2 replayed to the latest archived WAL, compared with production by row count on `pocket-id.schema_migrations` and `paperless.django_migrations`, which change only on upgrades.
- `dumps`: the newest encrypted dumps of `pocket-id` and `paperless`, decrypted on the Mac with the key on the offline medium and streamed into a scratch database on the primary, compared the same way. It needs the `bedrock-keys` stick and refuses to run unless `/Volumes/bedrock-keys/bedrock/gnupg-postgres-dumps` is mounted, so checks run by an agent without the owner name the drills explicitly, for example `just restore-test postgres`.
- `longhorn`: a restore of the newest backup of the Paperless data volume, which must refuse to unlock with a random wrong key and must unlock and list files with `longhorn-crypto`.
- `etcd`: the newest snapshot in `s3://bedrock-etcd/etcd-snapshots` must be under 13 hours old.

The cadence is a monthly `just restore-test` and `just offline-backup`, a full rebuild from git every six months, and both before a major upgrade. Nothing schedules them; they are run by hand.

| Mechanism | Last proven | Result |
| --- | --- | --- |
| Full rebuild from git | 2026-11-06 | Passed, about 2 h 20 min, four defects fixed in git |
| Age key decrypts `bedrock-secrets` | 2026-11-06 | Passed |
| Postgres clone from R2, replayed to the latest WAL | 2026-11-07 | Passed: 1 and 242 rows in both |
| Encrypted Longhorn restore, wrong key refused | 2026-11-07 | Passed |
| etcd snapshot in R2 under 13 hours old | 2026-11-07 | Passed |
| Encrypted dumps decrypted from the key stick into a scratch database | 2026-11-10 | Passed: 1 and 242 rows in both |
| Delete of a locked object with a bucket token refused | 2026-11-12 | Passed: `ObjectLockedByBucketPolicy` under `dumps/` and `etcd-snapshots/` |
| Offline copy to the key stick | 2026-11-12 | Passed: 1.3 GB copied, all four dumps decrypt |
| Host configurations build | Every pull request | `nix-check` in CI |
| etcd restore from a snapshot | Never | Untested |
| Postgres or a volume restored into production | Never | Untested |
| Re-key to new host keys | Never | Untested |
| Reinstall of a host's operating system | Never | Untested |

## Secret recovery

Host secrets use agenix. Each file under `secrets/` is encrypted to the host keys listed for it in `secrets/secrets.nix` and to the admin agenix key. When a host key changes:

1. Read the new key with `ssh-keyscan -t ed25519 <host>`.
2. Replace the recipient in `secrets/secrets.nix`.
3. Re-encrypt with the admin agenix identity: `agenix -r` re-keys every file, `agenix -e secrets/<name>.age` one.
4. Commit and rebuild the host.

K3s does not restart when `/run/agenix/k3s-token` changes in place, so a token rotation on a running cluster needs a manual restart of the agents.

Every SOPS file is encrypted to three age recipients, listed in both `.sops.yaml` files: the Secure Enclave identity, the new cluster key and the current cluster key. Run `sops` with `/opt/homebrew/bin` on `PATH` so it finds `age-plugin-se`. After any change to the recipient list, run `sops updatekeys -y <file>` on every SOPS file in both repositories. To switch bootstrap to the new key, set `SOPS_AGE_KEY_FILE=/Volumes/bedrock-keys/bedrock/age-cluster-2026-11.txt`; the current key is removed from both `.sops.yaml` files and the Mac once the rebuilt cluster decrypts with the new one.

Cluster secrets live in `bedrock-secrets` under `clusters/home/` (`platform/`, `identity/`, `apps/`), each folder with a kustomization listing its files. Edit with `sops <path>`; `just new-secret <app>` creates an app's pair. The one SOPS file in this repository, `kubernetes/clusters/home/bootstrap-secrets/bedrock-secrets-git-auth.sops.yaml`, holds the read-only deploy key for `bedrock-secrets` and is decrypted by the same age key, which makes that key the root of every cluster secret.

## Admin SSH keys

The admin keys are [Secretive](https://github.com/maxgoedjen/secretive) Secure Enclave keys, served to ssh by its agent at `~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh`:

- `estate-root` logs in to the hosts. Each use requires Touch ID.
- `github-push` authenticates to GitHub for pushes and fetches only. Each use requires Touch ID.
- `git-signing` signs every commit. It has Notify protection: Secretive shows a notification on each use and asks for nothing while the Mac is unlocked. It is registered on GitHub as a signing key and listed in `~/.ssh/allowed_signers`. Git uses it through `gpg.format ssh`, `user.signingkey ~/.ssh/git-signing.pub` and `gpg.ssh.program ~/.local/bin/git-ssh-sign`, a wrapper that runs `ssh-keygen` with `SSH_AUTH_SOCK` set to the Secretive agent. The repository rulesets require signed commits, so a Mac without this key cannot push.

The public half of `estate-root` is in `hosts/common/estate-root.pub`, which `scripts/deploy-nodes.sh` points `IdentityFile` at so ssh offers that key from the agent. The `sc_auth` and `/usr/lib/ssh-keychain.dylib` route was tried and produced cryptographically invalid signatures, so it is not used.

Every other host command (the README host commands, `scripts/refresh-kubeconfig.sh`, `scripts/luks-discards.sh`) runs plain `ssh`, `scp` or `nixos-rebuild --target-host root@<host>` and relies on two blocks in the Mac's `~/.ssh/config`. `~/.ssh/estate-root.pub` and `~/.ssh/github-push.pub` are the public halves exported from Secretive on that Mac:

```
Host control-plane-1 worker-1 worker-2 router 10.20.0.* 100.105.211.67 100.116.129.108 100.95.149.60 100.75.168.14
  User root
  IdentityAgent ~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh
  IdentityFile ~/.ssh/estate-root.pub
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m

Host github.com
  IdentityAgent ~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh
  IdentityFile ~/.ssh/github-push.pub
  IdentitiesOnly yes
```

A master connection stays open for 10 minutes and keeps the key it authenticated with, so after a key change `ssh -O exit <host>` closes it before the next login proves anything.

The keys carry no certificate and do not expire. They are rotated when the Mac is replaced:

1. Create a new key in Secretive and add its public key to `hosts/common/estate-root.pub`, which both Nix files read, as a second line next to the old one.
2. Deploy with `just deploy-nodes` and log in to every host with only the new key.
3. Remove the old key from that file and deploy again. The break-glass key is not rotated and stays in `hosts/common/estate-breakglass.pub`.

A lost Mac is recovered with the break-glass key below: log in with it from the new Mac, create new Secretive keys there, deploy their public keys, prove login with them, then remove the lost Mac's keys and deploy again. Reinstalling the nodes and reflashing the router with the `router-installer` image applies only if the stick is lost too ([Reinstalling a host](#reinstalling-a-host)).

The break-glass key is a passphrase-protected ed25519 key that lives only on `bedrock-keys` at `bedrock/ssh/estate-breakglass`. Its public key is a root key on every host beside `estate-root`. It is used when the Mac's Secure Enclave keys are unavailable: a lost Mac or a Secretive agent that is not running. From a Mac with the stick mounted and joined to the tailnet, the first hop is control-plane-1 over its own tailnet address, and VLAN 20 hosts follow from there:

```
ssh -i /Volumes/bedrock-keys/bedrock/ssh/estate-breakglass root@100.105.211.67
```

## Tailscale overlay recovery

Flannel runs over `tailscale0` on all three nodes ([ADR 0003](adr/0003-run-k3s-as-one-server-and-two-agents-on-the-tailnet.md)).

- A reinstalled host can carry a stale `/var/lib/tailscale/tailscaled.state` that points at another control server; `tailscaled-autoconnect` then times out. Move the state file aside before the switch.
- A NixOS activation that restarts tailscaled takes `tailscale0` down and can leave `flannel.1` bound to the old interface. After a Tailscale bump, compare each node's `flannel.alpha.coreos.com/public-ip` annotation and delete `flannel.1` where it drifted.
- An auth key is read only at first enrolment. A reinstalled host needs a new key encrypted into its secret before the switch.
- If tailscaled wedges on the Pi, restart it through the control-plane-1 jump (the `cp1-direct` config above), which reaches the Pi over VLAN 20 without its tailscaled. A power cycle is the fallback only when the Pi is unreachable on VLAN 20 too. The console does not help: the router configuration sets no password for root or any account, so no one can log in there. The nodes stay reachable over their own tailnet addresses throughout.

## Longhorn storage reserve

The chart sets `storageReservedPercentageForDefaultDisk: 30`, applied only when Longhorn creates a disk record, so the rebuilt nodes came up at 30 percent of their disks. A later change to the value reaches existing disks only by a patch to `spec.disks.<key>.storageReserved` on each `nodes.longhorn.io` object. Every disk key carries a generated suffix: read it with `kubectl -n longhorn-system get nodes.longhorn.io <node> -o jsonpath='{.spec.disks}'` first, because a merge patch on a missing key adds a second, broken disk entry. Keep `storage-over-provisioning-percentage` at 200 when raising the reserve, or replica scheduling stops on the smaller disks.

## Recovery objectives

| Data | Recovery point | Recovery time |
| --- | --- | --- |
| Everything declared in git | Zero | Bounded by reconciliation |
| Postgres | Up to about 5 minutes (`archive_timeout`), any point in 30 days | A recovery cluster replays WAL from the last base backup; not measured |
| Paperless and Open WebUI volumes | Up to 24 hours from R2, or from the nightly local snapshot | A restore per volume; not measured |
| Cluster API state | Up to 12 hours | Untested |
| The whole cluster with hardware on hand | As above per data class | About 2 h 20 min measured for a K3s-state rebuild, plus data restores |

## Known gaps

- Restores into production, the etcd restore and an operating system reinstall have never been run.
- control-plane-1 is the only API server. While it is down, running workloads keep serving, but nothing reschedules, and a CNPG instance that restarts cannot start, because its instance manager reads the Cluster from the API first.
- Postgres backups are plaintext in R2, which is an accepted risk.
- etcd snapshots in R2 are plaintext apart from Secrets and the bootstrap data, which is an accepted risk ([ADR 0004](adr/0004-keep-a-stable-cluster-ca-under-an-offline-root.md)).
- etcd disk latency is not monitored. etcd serves its metrics on loopback only, so the API server's view of etcd request latency (`EtcdRequestsSlow`) is the only etcd signal.
- Cloudflare R2 is the only continuous off-site copy, and the tunnel DNS records and Access applications are kept only in the Cloudflare dashboard. The offline copy is up to a month old.
- A stolen bucket token can erase the barman archive, every Longhorn backup and any dump or etcd snapshot older than its lock; the offline copy is then the newest Longhorn data that survives. A credential with R2 admin rights, such as a `wrangler login` session, can drop the lock rules first and erase everything in R2, which is why the wrangler session is logged out with `wrangler logout` outside lock maintenance.
- Alertmanager has no volume, so after a node loss its stranded pod waits until the node returns or the pod is deleted. The router's deadman marks the estate stale after four missed Watchdog pings ([ADR 0015](adr/0015-observe-with-prometheus-loki-and-tempo.md)).
- A mass reschedule outlasts its cause: every pod pulls through zot at once, and containerd does not fall back when the mirror is slow.
- Draining a node that holds the only replica of a disposable volume (Ollama, zot) blocks until Longhorn has evicted the replica to another node.
- A Postgres instance volume has one strict-local replica that can never move, so draining its node cannot evict it elsewhere. A server-side dry-run drain of worker-2 timed out on the `postgres-1` eviction (the `postgres-primary` PDB allows no disruption while that instance is primary) and on the Longhorn `instance-manager` eviction. Every `instance-manager` PDB allows 0 disruptions at baseline, so any drain of any node waits on it, not only a drain of a Postgres node; that was seen with and without a strict-local volume present. Under `nodeDrainPolicy: block-for-eviction-if-contains-last-replica` a strict-local last replica may block a drain indefinitely. This is unverified, because no real drain has been run. When the node holds the primary, `kubectl cnpg promote postgres <standby>` first moves the primary off it. The standby pod is then expected to be evicted, stay Pending while the node is cordoned and resume on the same node after `kubectl uncordon`, with no data loss; this is also unverified. The rolling-rebuild recipe must establish real drain behaviour, one node at a time with every instance ready between nodes, before relying on any of this.
- The drill cadence relies on the owner; no reminder is automated.

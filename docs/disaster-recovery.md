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

The age keys, the K3s root CA and the Longhorn volume encryption key are the three keys a rebuild cannot recreate. They are kept together on an encrypted offline medium (the APFS-encrypted `bedrock-keys` USB stick). The K3s root CA key lives only there; the cluster age key also sits in the `sops-age` Secret, and the Longhorn key also has a copy on the admin Mac ([ADR 0004](adr/0004-keep-a-stable-cluster-ca-under-an-offline-root.md)).

| Seed | Where it lives | Why it matters |
| --- | --- | --- |
| SOPS age key (2026-11) | `age-cluster-2026-11.txt` on the offline medium and the `sops-age` Secret in `flux-system` | Decrypts every file in `bedrock-secrets`, including the deploy key for that repository. `just bootstrap` reads it from `/Volumes/bedrock-keys/bedrock/age-cluster-2026-11.txt` unless `SOPS_AGE_KEY_FILE` says otherwise |
| SOPS age key (retired) | `age-keys.txt` on the offline medium | No longer a recipient: on 2026-11-13 every SOPS file was rotated to a new data key without it. It still decrypts the pre-rebuild git history, so it stays on the offline medium through the rollback window and is wiped together with the offline copy of the pre-rebuild backups, 30 days after the pre-rebuild objects are deleted from R2. The Mac copy `~/.config/sops/age/keys.txt` is deleted once the rotation is merged |
| SOPS age identity (Secure Enclave) | Secure Enclave of the Mac, created with `age-plugin-se`, referenced by `~/.config/sops/age/se-identity.txt`; only the public recipient is in git | A recipient on every SOPS file and the Mac's day-to-day decryption identity. It cannot be copied off the Mac |
| K3s root CA | `root-ca.pem` and `root-ca.key` in `/Volumes/bedrock-keys/bedrock/k3s-root-ca/` on the offline medium only; `scripts/generate-cluster-ca.sh` reads them there, or from `BEDROCK_ROOT_CA_DIR` | Signs the cluster CA in `secrets/k3s-ca.age`; the agent token pins the root. Without it, the next CA re-issue needs a new root and a re-pinned token |
| Longhorn volume encryption key | `CRYPTO_KEY_VALUE` of the `longhorn-crypto` Secret, from `clusters/home/platform/longhorn-crypto.sops.yaml` in `bedrock-secrets`, and `rebuild-keys/longhorn-crypto.key` on the offline medium | Opens every `longhorn-encrypted` volume. Losing it makes the encrypted Paperless and Open WebUI backups unrecoverable |
| Legacy Longhorn volume encryption key | `CRYPTO_KEY_VALUE` of the `longhorn-crypto-legacy` Secret, from `clusters/home/platform/longhorn-crypto-legacy.sops.yaml` in `bedrock-secrets`, and `longhorn-crypto.key` on the offline medium | The key before the 2026-11 rebuild. Opens the backups taken before it through the temporary `longhorn-encrypted-legacy` class |
| The two repositories | GitHub: `bedrock` and the private `bedrock-secrets` | Flux syncs from them |
| Admin host key | Secure Enclave key `estate-root` on the Mac, in `hosts/common/estate-root.pub`, read by `hosts/common/users.nix` and `hosts/router-installer.nix` | Root login on every host. It cannot be copied off the Mac |
| Break-glass host key | `/Volumes/bedrock-keys/bedrock/ssh/estate-breakglass` on the offline medium only, passphrase-protected | Root login on every host when the Secure Enclave keys are unavailable. Also an admin recipient on every agenix secret, so `agenix -d` and `agenix -r` work with it when the Mac is lost |
| Break-glass kubeconfig | `/Volumes/bedrock-keys/bedrock/kubeconfig-admin.yaml` on the offline medium only, written by `just kubeconfig-admin` | A `system:masters` client certificate that does not depend on Pocket ID. `just bootstrap` runs with it, and it is the only cluster access while Pocket ID is down. The Mac keeps only the Pocket ID context `bedrock`. Recreated from control-plane-1 whenever lost, as long as root SSH works |
| Admin agenix identity (Secure Enclave) | The SOPS Secure Enclave identity, referenced by `~/.config/sops/age/se-identity.txt` on the Mac | A recipient on every agenix secret beside the break-glass key; needed to re-key host secrets when a host key is lost. It cannot be copied off the Mac |
| Host SSH keys | `/etc/ssh/ssh_host_ed25519_key` on each host; for a full rebuild, generated ahead in `rebuild-keys/` on the offline medium | agenix secrets are encrypted to them. A reinstalled host gets new keys and cannot decrypt until the secrets are re-keyed, unless it is installed with the keys generated ahead |
| Secure Boot keys and LUKS recovery keys | `/var/lib/sbctl` on each node, and `rebuild-keys/` and `luks-recovery/` on the offline medium | Sign every boot of a node, and open its root when the TPM refuses ([ADR 0016](adr/0016-boot-nodes-through-secure-boot-and-unlock-luks-with-the-tpm.md)) |

The K3s server token (`secrets/k3s-token.age`), the agent join token (`secrets/k3s-agent-token.age`) and the etcd R2 credentials (`secrets/etcd-s3-credentials.age`) are in git as agenix files. The R2 credentials for Postgres and Longhorn, the Cloudflare tokens and every app secret are in `bedrock-secrets`. The accounts behind them (GitHub, Cloudflare, Tailscale, Anthropic) live outside both repositories.

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

The barman archives under `bedrock-postgres/postgres/` and `bedrock-postgres/postgres-2026-11/` and everything in `bedrock-longhorn` stay unlocked, because barman-cloud and Longhorn rewrite keys they have just written. No restore below deletes or overwrites a key under a locked prefix: the dumps and etcd snapshots are only read, and a recovered Postgres cluster archives under a new server name. Deleting old objects under a locked prefix, for example after a rebuild, waits until the lock has expired. `wrangler r2 object delete` prints `Delete complete` even when R2 refuses the delete of a locked object, so a delete is confirmed by reading the object back with `wrangler r2 object get` or through the S3 API, which returns the refusal. `wrangler r2 bucket lock list <bucket>` shows the rules, and `wrangler r2 bucket lock remove <bucket> --name <rule>` drops one.

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

### 2026-11-13 rebuild with disk encryption

All four hosts were reinstalled from the flake, and Postgres and the Longhorn volumes were restored from R2 into the new cluster. Times are CET (UTC+1), to the minute.

| Phase | Start | End | Duration |
| --- | --- | --- | --- |
| Pre-wipe backups | 11:13 | 11:35 | 22 min |
| Switch reset and setup | 11:50 | 12:04 | 14 min |
| Router reflash | 12:07 | 12:50 | 43 min |
| control-plane-1 | 12:58 | 13:32 | 34 min |
| worker-1 | 13:34 | 13:49 | 15 min |
| worker-2 | 13:50 | 14:03 | 13 min |
| Bootstrap to all 47 Kustomizations Ready | 14:26 | 16:54 | up to 2 h 28 min |
| Postgres recovery | 15:20 | 15:47 | 27 min |
| Longhorn volume restores | 15:48 | 16:04 | 16 min |
| Final verification | 16:54 | - | - |

The bootstrap end is an upper bound, the time all Kustomizations were confirmed Ready. The node, bootstrap and restore rows overlap the interruptions below.

Final verification found 3 nodes Ready, 47 of 47 Kustomizations and the data checks passed; rechecked 20:38.

Hands-on interruptions:

- control-plane-1: a missed Secretive approval and the `systemd-pcrlock` failure ([ADR 0016](adr/0016-boot-nodes-through-secure-boot-and-unlock-luks-with-the-tpm.md)) held the install 13:17 to 13:24, 7 min.
- worker-2: a missed Secretive approval cut the installer connection; restarted from the disk step, running again by 13:55, 2 min.
- Flannel kept the temporary tailnet addresses as public addresses, breaking inter-node traffic; Flux stalled 15:11 to 15:19 until K3s was restarted on every node, 8 min.
- The Postgres recovery job could not reach R2 because `allow-internet-egress` did not select it. Seen about 15:36, recovered 15:47, 11 min including the policy fix, push and recreated job.
- zot rejected the Docker schema 2 gotenberg manifest until `http.compat` allowed `docker2s2`: 32 min, 16:22 to 16:54.

## Rebuilding the cluster from git

This is the procedure as run on 2026-11-06, with the fixes in place. It wipes the K3s state and keeps the operating systems. A reinstall of the operating systems is covered in [Full rebuild from git with disk encryption](#full-rebuild-from-git-with-disk-encryption).

### Before the wipe

1. Confirm the seeds: `sops -d` of a file in `bedrock-secrets` succeeds with the age key, and on control-plane-1 both `/run/agenix/k3s-token` and `/run/agenix/k3s-ca` exist, so the cluster CA in `secrets/k3s-ca.age` decrypts there.
2. Run `nix flake check` and every `scripts/check-*.sh`.
3. If `main` carries changes the running cluster has not applied, freeze the cluster before pushing, so it never applies them or writes into R2: annotate the `FluxInstance` with `fluxcd.controlplane.io/reconcile: disabled`, then `flux suspend source git flux-system` and suspend every Kustomization and HelmRelease. `flux suspend` takes no `-A`, so loop over the namespaces with `--all -n <namespace>`.
4. Decide what happens to the data: a rebuild that discards it, or one that keeps it and follows [Restoring data from R2](#restoring-data-from-r2). The first step of [Bootstrap and converge](#bootstrap-and-converge) depends on the choice.

### Wipe and rebuild the nodes

1. `just deploy-nodes` is the normal path for routine rebuilds; this runbook keeps its own jump config for cold rebuilds, when the recipe cannot run. Rebuild the router first if its configuration changed, through control-plane-1's own tailnet address: a router switch restarts tailscaled and cuts any session through the Pi's subnet route. An SSH config file for the jump:

   ```
   Host cp1-direct
     HostName control-plane-1.tail26ab10.ts.net
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

   `control-plane-1.tail26ab10.ts.net` is control-plane-1's MagicDNS name from `lib/inventory.nix`. `NIX_SSHOPTS` is split on spaces, so the jump goes in a config file rather than an inline `ProxyCommand`.
2. Build and stage the new generation on every node with `nixos-rebuild boot` (see [Changing a host](../README.md#changing-a-host) for `--build-host`), so each node comes up once, fresh, on the new generation.
3. On worker-2, then worker-1, then control-plane-1: `systemctl stop k3s` and `k3s-killall.sh`, then confirm that `findmnt` lists nothing under `/var/lib/kubelet` or `/var/lib/longhorn`. A Longhorn CSI mount whose engine lived on an already stopped node can hang the forced unmount; `umount -l` clears it.
4. Remove the state and purge the iSCSI node records in the same command as the reboot, since stale records break the next attach in either direction. Reboot control-plane-1 first:

   ```
   rm -rf /var/lib/rancher/k3s /etc/rancher/k3s /var/lib/longhorn /var/lib/kubelet /etc/iscsi/nodes && systemctl reboot
   ```

   NixOS recreates the files it manages under `/etc/rancher/k3s` on boot.
5. control-plane-1 starts with `clusterInit`. The `k3s-ca` unit unpacks `secrets/k3s-ca.age` into `/var/lib/rancher/k3s/server/tls` because no `server-ca.crt` exists, so the server comes back with the same CA and the agents join with the unchanged token. `KUBECONFIG=/Volumes/bedrock-keys/bedrock/kubeconfig-admin.yaml kubectl get nodes` shows three Ready nodes once `just kubeconfig-admin` has written the new admin certificate.

### Bootstrap and converge

1. After the wipe and before `just bootstrap`, check the R2 targets with each bucket's own credentials. Flux creates the `postgres` Cluster by `recovery` from server name `postgres`, and it archives under server name `postgres-2026-11`, so its archive check fails if `s3://bedrock-postgres/postgres-2026-11/` already holds WAL from an earlier cluster; a BackupVolume left in `bedrock-longhorn` re-syncs into the new cluster. For a rebuild that discards data, switch `bootstrap` in `kubernetes/infrastructure/configs/cnpg/cnpg-cluster.yaml` back to `initdb` first, since the `recovery` source needs the archive under `postgres/`, then delete what is there once the owner confirms. For a rebuild that keeps data, leave both and restore as in [Restoring data from R2](#restoring-data-from-r2).
2. Run `just bootstrap` ([README](../README.md#flux)). It writes the break-glass kubeconfig to the stick and runs every step with it, applies CoreDNS, installs the flux-operator chart, applies the `FluxInstance`, creates `sops-age` and the sync deploy key, and waits for the `FluxInstance`.
3. Let `just bootstrap` register the printed public key as the read-only deploy key `flux-home-cluster` (or add it by hand with Allow write access unchecked), and delete the previous cluster's key. Nothing in the cluster writes to git.
4. Open `https://id.syslabs.dev/setup` as soon as Pocket ID runs and register the owner passkey; the claim page is open to the home LAN until then. In the Pocket ID admin UI, mark the owner email as verified. oauth2-proxy rejects an unverified email, and every forward-auth login answers 500 until this is done ([ADR 0010](adr/0010-sign-in-through-pocket-id-and-oauth2-proxy.md)). Then run `just kubeconfig` and `kubectl --context bedrock get nodes`; the passkey login proves the Pocket ID path before the stick goes back in the drawer.
5. Check that the public DNS records for `chat.syslabs.dev` and `lucawalz.dev` still point at the tunnel. They are made by hand in the Cloudflare dashboard.
6. Watch `flux get kustomizations -A` and `flux get helmreleases -A` until everything is Ready. Any stall gets a root-cause fix in git, never a live patch.

### Cold-start behaviour to expect

- Pods with multi-gigabyte images (Ollama, Open WebUI) sit in `ImagePullBackOff` for a while. zot fetches an image fully before it answers the manifest request, the containerd pull deadline cancels the request first, and containerd does not fall back to the upstream registry. They recover once zot has the image.
- The `bedrock-secrets` GitRepository can wait up to its 10 minute interval before its deploy key Secret exists. `flux reconcile source git bedrock-secrets -n flux-system` shortens the wait.
- The `cluster-cnpg-db` Kustomization can time out once while the Postgres instances recover from R2, and pass on the retry.
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

`just restore-test postgres` creates a one-instance `postgres-restore-test` Cluster that bootstraps by `recovery` from the `postgres-backup` ObjectStore (server name `postgres-2026-11`) through the barman-cloud plugin. The production Cluster in `kubernetes/infrastructure/configs/cnpg/cnpg-cluster.yaml` bootstraps by `recovery` from the archive of server name `postgres`, written by the cluster before the 2026-11 rebuild, and its WAL archiver writes under the new server name `postgres-2026-11`, so it never writes into the archive it reads from. The next rebuild that keeps data moves the recovery source to `postgres-2026-11` and the archiver to a newer server name, before Flux first creates the Cluster. The Cluster declares `longhorn-encrypted-local`, so the recovered instances land on LUKS volumes with one strict-local replica each; run `just luks-discards postgres/postgres-<n>` for each instance PVC once it is attached, or `filesystem-trim` frees nothing. For a single app, `just dump` and `just restore` move one database without touching the others.

If the barman archive is unusable, the nightly logical dumps in `bedrock-postgres/dumps/<database>/<UTC time>.gpg` are the fallback; the newest key sorts last. They are encrypted to the OpenPGP key on the offline medium: `gpg --homedir /Volumes/bedrock-keys/bedrock/gnupg-postgres-dumps --decrypt` reads one on stdin and writes the `pg_dump` custom-format archive to stdout, which `kubectl exec -i` into the primary can feed straight to `pg_restore`, so the plaintext never touches the disk.

### Longhorn volumes

Longhorn lists the backups in `bedrock-longhorn` once its BackupTarget polls the bucket. A volume restored from a backup must exist before the app's claim binds to a fresh empty volume, so the app's Kustomization is suspended, the restored volume is bound to the claim name the app expects, and the Kustomization is resumed. `just restore-test longhorn` shows the restore and the binding as a static PersistentVolume. Encrypted volumes need the `longhorn-crypto` Secret in place first; `bedrock-secrets` provides it, or the offline copy if the repository is gone. A static PersistentVolume never reads a StorageClass, so a volume backed up before the 2026-11 rebuild names `longhorn-crypto-legacy` in its `csi.nodeStageSecretRef` instead.

### etcd

A snapshot restores the whole Kubernetes API state. It is the right tool only when the API holds state that Flux cannot reconcile back. The server token governs the restore: a snapshot restored under a different token gives a cluster that starts and returns ciphertext for every Secret, without an error. On control-plane-1, as root, with the token and the S3 credentials that the `k3s` unit reads from agenix:

```
systemctl stop k3s
set -a; . /run/agenix/etcd-s3-credentials; set +a
k3s server --cluster-reset --secrets-encryption --secrets-encryption-provider=secretbox --token-file=/run/agenix/k3s-token \
  --etcd-s3 --etcd-s3-bucket=bedrock-etcd --etcd-s3-folder=etcd-snapshots \
  --etcd-s3-endpoint=<account id>.r2.cloudflarestorage.com --etcd-s3-region=auto \
  --cluster-reset-restore-path=<snapshot name>
```

`--secrets-encryption` and its `secretbox` provider are needed here too, or the API server cannot read what it restored. Then start K3s normally and restart the agents, since `--cluster-reset` drops every peer. Reading `flux-system/sops-age` and getting decodable data proves that the token, the encryption config and the snapshot agree. This restore has never been run. Rehearsing it needs an isolated host with no route to VLAN 20, started with `--disable-agent`, because a restored snapshot carries the live MetalLB pools, Flux sources and issuers. Treat that host as holding production secrets and destroy it afterwards.

## Losing a node that hosts Postgres

The Cluster declares `longhorn-encrypted-local` for its instance volumes: LUKS with one strict-local replica, bound to the node of the first attach. A storage class change reaches only PVCs created afterwards, so a Cluster that predates the class keeps unencrypted volumes until recovered onto it ([ADR 0007](adr/0007-share-one-cloudnativepg-cluster-with-per-app-databases.md)); since 2026-11-13 all three instances are on `longhorn-encrypted-local`. When that node or its disk is lost for good, the instance's PVC stays pinned to it, CloudNativePG does not delete a PVC on its own, and the pod stays Pending. The required anti-affinity across three nodes also leaves no other node for a fourth instance. If the node returns with its disk intact, the pod resumes by itself. Otherwise replacement is manual:

```
kubectl cnpg destroy postgres <n>
just luks-discards postgres/postgres-<m>
```

`kubectl cnpg destroy` removes the instance pod and its PVCs ([CloudNativePG kubectl plugin](https://cloudnative-pg.io/docs/1.30/kubectl-plugin)); the plugin is a krew install, not part of the dev shell. CloudNativePG then creates a new instance with a new number, clones it from a sibling and the new PVC is the one to pass to `just luks-discards` once it is attached. Without the plugin, deleting the instance's pod and PVCs with `kubectl delete` has the same effect (not verified against the CloudNativePG docs). If the lost instance was the primary, a standby has been promoted already. While one instance is missing, the cluster keeps `dataDurability: preferred` and serves writes.

### Planned drain

One node at a time:

1. `kubectl cnpg promote postgres <standby>` to move the primary off the node.
2. `kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=300s`, accepting the `instance-manager` block.
3. `systemctl reboot` on the node, then `kubectl uncordon <node>`.
4. Wait for 3 ready instances before the next node.

Measured on worker-2 on 2026-11-13 (CET, 20:56 to 21:09), which held the primary: the promote took 27 s. The drain evicted the standby, which went Pending, but blocked the full 300 s on the `instance-manager` PodDisruptionBudget and left the node cordoned. The kernel was up 1 min 48 s after the reboot with TPM unlock unattended, and 3 instances were ready 7 min 14 s after it, with `postgres-1` back on the same strict-local volume. The time the standby stays Pending while cordoned after a reboot was not measured.

## Full rebuild from git with disk encryption

This reinstalls all four hosts from the flake: the three nodes onto a LUKS2 root with TPM2 unlock and Secure Boot ([ADR 0016](adr/0016-boot-nodes-through-secure-boot-and-unlock-luks-with-the-tpm.md)), the router onto an unencrypted SD card. Every disk is wiped, so the data comes back from R2. It reuses the steps of [Rebuilding the cluster from git](#rebuilding-the-cluster-from-git) where they apply. The steps ran once, on 2026-11-13 (see the [timeline](#2026-11-13-rebuild-with-disk-encryption)). Commands run from the repository root in the dev shell on the Mac, with the `bedrock-keys` stick mounted.

### Contents of the stick

Before anything is wiped, `/Volumes/bedrock-keys/bedrock/` holds:

- [ ] `age-cluster-2026-11.txt`, the cluster age key
- [ ] `k3s-root-ca/root-ca.pem` and `k3s-root-ca/root-ca.key`
- [ ] `longhorn-crypto.key`, the current Longhorn key, which becomes the legacy key
- [ ] `ssh/estate-breakglass` and its passphrase
- [ ] `gnupg-postgres-dumps/`, which decrypts the logical dumps
- [ ] `rclone/offline-backup.conf`, and `/Volumes/bedrock-keys/bedrock-offline/` with a copy taken after the final backups below
- [ ] `rebuild-keys/`, written by `just generate-rebuild-keys`:
  - `k3s-token` and `k3s-agent-token`, the new server and agent tokens, both pinning the hash of the root CA
  - `longhorn-crypto.key`, the new Longhorn key
  - `luks-install-passphrase`, used once by disko and wiped after the TPM enrolment
  - `hosts/<host>/etc/ssh/ssh_host_ed25519_key` and `.pub` for control-plane-1, worker-1, worker-2 and router
  - `hosts/<node>/var/lib/sbctl/GUID` and `keys/{PK,KEK,db}/{PK,KEK,db}.{key,pem}` for each node

During the run it gains `kubeconfig-admin.yaml`, written after the cluster CA is re-issued, and `luks-recovery/<node>`, one recovery key per node.

### Prepare

1. Generate the keys once: `just generate-rebuild-keys`. It refuses to run while `rebuild-keys/` exists, writes every file mode 600, and prints only the paths, the CA hash the tokens pin and the four host public keys.
2. Prepare the commits on a local branch in each repository, never on `main`, because a push before the old nodes are wiped would hand the running cluster a Longhorn key that opens none of its volumes. In `bedrock`, on `feat/rebuild-install`: the new host public keys from `rebuild-keys/hosts/<host>/etc/ssh/ssh_host_ed25519_key.pub` in `secrets/secrets.nix`, every file re-keyed from `secrets/` as in [Secret recovery](#secret-recovery), the first time with the old admin key `~/.ssh/id_ed25519`, since the old files are not encrypted to the Secure Enclave identity, the new tokens with the agent token wired separately (a new `k3s-agent-token` agenix secret encrypted to all three nodes and the admins, `services.k3s.agentTokenFile` on control-plane-1 and `services.k3s.tokenFile` on the agents pointing at it, and `k3s-token.age` limited to control-plane-1 and the admins), new single-use Tailscale auth keys (`tag:cluster` for the nodes, `tag:router` for the router) encrypted to the new host keys, the cluster CA re-issued with `scripts/generate-cluster-ca.sh`, and the Postgres `bootstrap.recovery` with a new archive server name as in [Postgres](#postgres). In `bedrock-secrets`, on the same branch name: `longhorn-crypto` with the new key and `longhorn-crypto-legacy` with the current one.
3. Stop the writes and take the final backups. Suspend and scale every app with a database or a volume to zero as `just restore` does (`flux suspend kustomization <app>`, then `kubectl -n <app> scale deploy,statefulset --all --replicas 0`), then:

   ```
   just backup
   ```

   Back up each volume labelled `offsite-backup` on demand from the Longhorn UI (not proven), and take an etcd snapshot on control-plane-1 (not proven):

   ```
   set -a; . /run/agenix/etcd-s3-credentials; set +a
   k3s etcd-snapshot save --etcd-s3 --etcd-s3-bucket=bedrock-etcd --etcd-s3-folder=etcd-snapshots \
     --etcd-s3-endpoint=<account id>.r2.cloudflarestorage.com --etcd-s3-region=auto
   ```

   `just backup` takes a base backup only, and the logical dumps run daily at 03:30, so run one dump now and wait for it (not proven):

   ```
   kubectl -n postgres create job --from=cronjob/postgres-dump postgres-dump-rebuild
   kubectl -n postgres wait --for=condition=complete job/postgres-dump-rebuild --timeout=2h
   ```

   Then prove the backups are fresh and readable, and copy them to the stick:

   ```
   just restore-test all --max-age 2h
   just offline-backup /Volumes/bedrock-keys
   ```

4. Build the router SD image while control-plane-1 still builds aarch64 (not proven):

   ```
   nix build --eval-store auto --store ssh-ng://root@10.20.0.10 --print-out-paths .#nixosConfigurations.router-installer.config.system.build.sdImage
   nix copy --no-check-sigs --from ssh-ng://root@10.20.0.10 <store path>
   zstd -d <store path>/sd-image/<image>.img.zst -o router-installer.img
   ```

5. Cherry-pick the prepared commits onto the local `main` of each repository, oldest first, and delete the branch. Nothing is pushed yet.

   ```
   git switch main
   git cherry-pick main..feat/rebuild-install
   git branch -D feat/rebuild-install
   ```

### Switch

Reset the TL-SG108PE while everything is down (not proven). A factory reset power-cycles the Pi, which draws PoE from port 2. Reach the switch at its factory default address with the Mac on a spare port (3 to 5) and a static address in that range, set a new admin password and keep it in the Passwords app, re-enter the static address `192.168.2.212`, gateway `192.168.2.1`, and the port map from [archived ADR 0050](adr/archive/0050-poe-switch-powers-the-router.md), and update the firmware. The switch is done when the Mac reaches `192.168.2.212` and the Pi trunk carries VLAN 20 and 30.

### Router

The router is reflashed, not installed with nixos-anywhere (not proven):

1. In the Tailscale admin console, delete the router's old device before the Pi first joins with its auth key, and do not restore its old address. Flash `router-installer.img` to the SD card and boot the Pi. The installer accepts root logins with `estate-root` and the break-glass key on its home LAN address `192.168.2.211`.
2. Place the pre-generated host key before the first switch, so the router decrypts its agenix secrets:

   ```
   ssh-keygen -R 192.168.2.211
   tar -C /Volumes/bedrock-keys/bedrock/rebuild-keys/hosts/router -cf - etc | ssh root@192.168.2.211 'tar -C / -xf - --no-same-owner && systemctl restart sshd'
   ```

3. Push the configuration, built on the Pi itself:

   ```
   nixos-rebuild switch --flake .#router --target-host root@192.168.2.211 --build-host root@192.168.2.211
   ```

4. Confirm that the Mac reaches `10.20.0.1` through the subnet route before touching the nodes.

### Nodes

control-plane-1 first, then worker-1, then worker-2, each wipe confirmed by the owner (not proven):

1. In the firmware settings, put Secure Boot into setup mode. In the Tailscale admin console, delete the node's old device before the first boot, when the reinstalled node joins with its auth key. With the old device gone it joins under its plain hostname; otherwise it joins as `<hostname>-1`, and a rename in the console fixes the name without changing the address. The new device keeps whatever address it gets: old addresses are not restored, and K3s needs no restart.
2. Install from the local `main`:

   ```
   just install-node control-plane-1
   ```

   The recipe refuses unless the repository is on a clean `main`, the node's keys are on the stick and the node's address from `lib/inventory.nix` answers as that node or as the installer. nixos-anywhere logs in with `estate-root` through the Secretive agent over one multiplexed session and copies `rebuild-keys/hosts/<node>` into the new system with `--extra-files`, keeping its modes, so lanzaboote signs the first generation with the keys under `/var/lib/sbctl`. disko asks for the LUKS passphrase twice and reads it from the terminal only; the recipe puts it on the clipboard and clears the clipboard on exit, since Universal Clipboard can carry it to other devices. Still in the installer, the recipe enrols the Secure Boot keys from that bundle with the Microsoft keys included, as the lanzaboote documentation does, checks the owner GUID against the stick and reboots. After a failed login, `just install-node <node> phases=disko,install` resumes in the running installer without a new kexec.
3. At the console, enable Secure Boot in the firmware and type the install passphrase at the first boot.
4. Bind the root to the TPM as ADR 0016 states:

   ```
   just enrol-node-tpm control-plane-1
   ```

   The recipe pins the host key from `rebuild-keys/hosts/<node>/etc/ssh/ssh_host_ed25519_key.pub` and refuses unless `bootctl status` reports `Secure Boot: enabled (user)` and `/Volumes/bedrock-keys/bedrock/luks-recovery/<node>` does not exist yet. It enrols the TPM with PCRs 0+7, writes a recovery key straight to that file without printing it, and wipes the passphrase slot only once `cryptsetup luksDump` shows both the tpm2 and the recovery token.
5. Reboot twice without a keyboard: each boot unlocks from the TPM, `lsblk` shows a `crypt` device under the root, and on the workers `/run/agenix` holds the agent token and not the server token.

Once all three old nodes are wiped, push `main` of both repositories. After control-plane-1 is up, `just kubeconfig-admin` writes the break-glass kubeconfig signed by the re-issued CA onto the stick.

### Bootstrap and restore

1. Bootstrap with the cluster age key and the stick kubeconfig, naming the key file because the Mac's own `SOPS_AGE_KEY_FILE` would override the default:

   ```
   SOPS_AGE_KEY_FILE=/Volumes/bedrock-keys/bedrock/age-cluster-2026-11.txt \
     BEDROCK_ADMIN_KUBECONFIG=/Volumes/bedrock-keys/bedrock/kubeconfig-admin.yaml just bootstrap
   ```

   Then continue with steps 3 to 6 of [Bootstrap and converge](#bootstrap-and-converge). `just kubeconfig` is re-run, because the Mac's context embeds the old server CA.
2. Postgres recovers from R2 on its first reconcile through the prepared `bootstrap.recovery`; run `just luks-discards postgres/postgres-<n>` on each instance volume once attached. The Longhorn volumes are restored as in [Longhorn volumes](#longhorn-volumes), each static PersistentVolume naming `longhorn-crypto-legacy` in its `csi.nodeStageSecretRef`.
3. Verify as in [Verify](#verify), and `just restore-test all` once the first backups of the new cluster exist.
4. A wiped node comes back with empty disks, so a Postgres instance volume on the declared class is gone with it; replace that instance as in [Losing a node that hosts Postgres](#losing-a-node-that-hosts-postgres).

## Restore drills

`just restore-test` runs four drills and removes everything it creates. `all` runs `dumps` last, because only that drill needs the key stick:

- `postgres`: a clone from R2 replayed to the latest archived WAL, compared with production by row count on `pocket-id.schema_migrations` and `paperless.django_migrations`, which change only on upgrades.
- `dumps`: the newest encrypted dumps of `pocket-id` and `paperless`, decrypted on the Mac with the key on the offline medium and streamed into a scratch database on the primary, compared the same way. It needs the `bedrock-keys` stick and refuses to run unless `/Volumes/bedrock-keys/bedrock/gnupg-postgres-dumps` is mounted, so checks run by an agent without the owner name the drills explicitly, for example `just restore-test postgres`.
- `longhorn`: a restore of the newest backup of the Paperless data volume, which must refuse to unlock with a random wrong key and must unlock and list files with `longhorn-crypto`.
- `etcd`: the newest snapshot in `s3://bedrock-etcd/etcd-snapshots` must be under 13 hours old.

`--max-age <n>s|m|h|d`, for example `just restore-test all --max-age 2h`, also fails each drill whose newest backup is older: the newest completed base backup for `postgres`, the newest dump of each database for `dumps`, the restored backup for `longhorn`, and the snapshot for `etcd`.

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

Host secrets use agenix. Each file under `secrets/` is encrypted to the host keys listed for it in `secrets/secrets.nix` and to two admin recipients: the admin agenix key and the break-glass key. When a host key changes:

1. Read the new key with `ssh-keyscan -t ed25519 <host>`.
2. Replace the recipient in `secrets/secrets.nix`.
3. Re-encrypt from the `secrets/` directory, where `agenix` finds `secrets.nix`, with `/opt/homebrew/bin` on `PATH` so `age` finds `age-plugin-se`: `agenix -r -i ~/.config/sops/age/se-identity.txt` re-keys every file, `agenix -e <name>.age -i ~/.config/sops/age/se-identity.txt` one. Without the Mac, `-i /Volumes/bedrock-keys/bedrock/ssh/estate-breakglass` decrypts instead.
4. Commit and rebuild the host.

K3s does not restart when `/run/agenix/k3s-token` or `/run/agenix/k3s-agent-token` changes in place, so a token rotation on a running cluster needs a manual restart of K3s on every node that reads the changed file.

Every SOPS file is encrypted to two age recipients, listed in both `.sops.yaml` files: the Secure Enclave identity and the cluster key `age-cluster-2026-11.txt`. Run `sops` with `/opt/homebrew/bin` on `PATH` so it finds `age-plugin-se`, and with `SOPS_AGE_KEY_FILE=~/.config/sops/age/se-identity.txt` to decrypt on the Mac. After adding a recipient, run `sops updatekeys -y <file>` on every SOPS file in both repositories. After removing one, run `sops rotate -i --rm-age <recipient> <file>` so every file gets a new data key.

Cluster secrets live in `bedrock-secrets` under `clusters/home/` (`platform/`, `identity/`, `apps/`), each folder with a kustomization listing its files. Edit with `sops <path>`; `just new-secret <app>` creates an app's pair. The one SOPS file in this repository, `kubernetes/clusters/home/bootstrap-secrets/bedrock-secrets-git-auth.sops.yaml`, holds the read-only deploy key for `bedrock-secrets` and is decrypted by the same age key, which makes that key the root of every cluster secret.

## Admin SSH keys

The admin keys are [Secretive](https://github.com/maxgoedjen/secretive) Secure Enclave keys, served to ssh by its agent at `~/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh`:

- `estate-root` logs in to the hosts. Each use requires Touch ID.
- `github-push` authenticates to GitHub for pushes and fetches only. Each use requires Touch ID.
- `git-signing` signs every commit. It has Notify protection: Secretive shows a notification on each use and asks for nothing while the Mac is unlocked. It is registered on GitHub as a signing key and listed in `~/.ssh/allowed_signers`. Git uses it through `gpg.format ssh`, `user.signingkey ~/.ssh/git-signing.pub` and `gpg.ssh.program ~/.local/bin/git-ssh-sign`, a wrapper that runs `ssh-keygen` with `SSH_AUTH_SOCK` set to the Secretive agent. The repository rulesets require signed commits, so a Mac without this key cannot push.

The public half of `estate-root` is in `hosts/common/estate-root.pub`, which `scripts/deploy-nodes.sh` points `IdentityFile` at so ssh offers that key from the agent. The `sc_auth` and `/usr/lib/ssh-keychain.dylib` route was tried and produced cryptographically invalid signatures, so it is not used.

Every other host command (the README host commands, `scripts/refresh-kubeconfig.sh`, `scripts/luks-discards.sh`) runs plain `ssh`, `scp` or `nixos-rebuild --target-host root@<host>` and relies on two blocks in the Mac's `~/.ssh/config`. `~/.ssh/estate-root.pub` and `~/.ssh/github-push.pub` are the public halves exported from Secretive on that Mac:

```
Host control-plane-1 worker-1 worker-2 router 10.20.0.* control-plane-1.tail26ab10.ts.net worker-1.tail26ab10.ts.net worker-2.tail26ab10.ts.net router.tail26ab10.ts.net
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

The keys carry no certificate and do not expire. They are rotated when the Mac is replaced and the old Mac still works:

1. On the new Mac, create `estate-root`, `github-push` and `git-signing` in Secretive and export their public keys to `~/.ssh/`. Register `github-push` on GitHub as an authentication key and `git-signing` as a signing key, and add `git-signing` to `~/.ssh/allowed_signers`.
2. On the new Mac, copy the new `estate-root` public key to `hosts/common/estate-root-next.pub`, commit and push it. While that file is tracked, both Nix files install it as a root key next to `estate-root.pub`, and `scripts/deploy-nodes.sh` offers it as a second identity.
3. On the old Mac, pull and run `just deploy-nodes`. It logs in with the old key and installs the new one on every host.
4. On the new Mac, log in to every host with the new key, then `git mv hosts/common/estate-root-next.pub hosts/common/estate-root.pub`, commit and run `just deploy-nodes`. That deploy logs in with the new key and removes the old one.
5. Remove the old Mac's `github-push` and `git-signing` keys from GitHub.

The break-glass key is not rotated and stays in `hosts/common/estate-breakglass.pub`.

A lost Mac is recovered from the stick. On the new Mac, with the stick mounted and the Mac joined to the tailnet:

1. Create the three keys and register them as in step 1 above.
2. Replace `hosts/common/estate-root.pub` with the new `estate-root` public key and commit it.
3. Deploy with the break-glass key: `BEDROCK_SSH_IDENTITY=/Volumes/bedrock-keys/bedrock/ssh/estate-breakglass just deploy-nodes`. With that variable set, the generated ssh config, `NIX_SSHOPTS` and the probes offer only that key, with `IdentitiesOnly yes` and no agent, so ssh asks for the key's passphrase, possibly more than once. The deploy removes the lost Mac's `estate-root` from every host.
4. Prove login with the new key, then remove the lost Mac's keys from GitHub.
5. Re-key agenix without the Mac's agenix key: replace the `luca-secure-enclave` recipient in `secrets/secrets.nix` with a new admin recipient, then run `agenix -r -i /Volumes/bedrock-keys/bedrock/ssh/estate-breakglass` from `secrets/`.

Reinstalling the nodes and reflashing the router with the `router-installer` image applies only if the stick is lost too ([Full rebuild from git with disk encryption](#full-rebuild-from-git-with-disk-encryption)).

The break-glass key is a passphrase-protected ed25519 key that lives only on `bedrock-keys` at `bedrock/ssh/estate-breakglass`. Its public key is a root key on every host beside `estate-root`. It is used when the Mac's Secure Enclave keys are unavailable: a lost Mac or a Secretive agent that is not running. From a Mac with the stick mounted and joined to the tailnet, the first hop is control-plane-1 over its own tailnet device, by its MagicDNS name, and VLAN 20 hosts follow from there:

```
ssh -i /Volumes/bedrock-keys/bedrock/ssh/estate-breakglass root@control-plane-1.tail26ab10.ts.net
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
| Postgres | Up to about 5 minutes (`archive_timeout`), any point in 30 days | A recovery cluster replays WAL from the last base backup; 27 min measured on 2026-11-13, including the egress fix |
| Paperless and Open WebUI volumes | Up to 24 hours from R2, or from the nightly local snapshot | A restore per volume; 16 min measured on 2026-11-13 for all five |
| Cluster API state | Up to 12 hours | Untested |
| The whole cluster with hardware on hand | As above per data class | About 2 h 20 min measured for a K3s-state rebuild, plus data restores |

## Known gaps

- The etcd restore has never been run. Restores into production and an operating system reinstall have run once, on 2026-11-13.
- control-plane-1 is the only API server. While it is down, running workloads keep serving, but nothing reschedules, and a CNPG instance that restarts cannot start, because its instance manager reads the Cluster from the API first.
- Postgres backups are plaintext in R2, which is an accepted risk.
- etcd snapshots in R2 are plaintext apart from Secrets and the bootstrap data, which is an accepted risk ([ADR 0004](adr/0004-keep-a-stable-cluster-ca-under-an-offline-root.md)).
- etcd disk latency is not monitored. etcd serves its metrics on loopback only, so the API server's view of etcd request latency (`EtcdRequestsSlow`) is the only etcd signal.
- Cloudflare R2 is the only continuous off-site copy, and the tunnel DNS records and Access applications are kept only in the Cloudflare dashboard. The offline copy is up to a month old.
- A stolen bucket token can erase the barman archive, every Longhorn backup and any dump or etcd snapshot older than its lock; the offline copy is then the newest Longhorn data that survives. A credential with R2 admin rights, such as a `wrangler login` session, can drop the lock rules first and erase everything in R2, which is why the wrangler session is logged out with `wrangler logout` outside lock maintenance.
- Alertmanager has no volume, so after a node loss its stranded pod waits until the node returns or the pod is deleted. The router's deadman marks the estate stale after four missed Watchdog pings ([ADR 0015](adr/0015-observe-with-prometheus-loki-and-tempo.md)).
- A mass reschedule outlasts its cause: every pod pulls through zot at once, and containerd does not fall back when the mirror is slow.
- Draining a node that holds the only replica of a disposable volume (Ollama, zot) blocks until Longhorn has evicted the replica to another node.
- A strict-local Postgres volume cannot move and every Longhorn `instance-manager` PodDisruptionBudget allows 0 disruptions, so every drain blocks until its timeout.
- The procedure and measured result are in [Planned drain](#planned-drain).
- The drill cadence relies on the owner; no reminder is automated.

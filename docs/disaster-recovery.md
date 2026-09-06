# Disaster recovery

How to rebuild the cluster from nothing, what has to survive outside it, and how to rehearse the recovery without causing an outage.

GitOps reconciles everything declared in this repository, so recovery is mostly a matter of reapplying it. What the repository cannot hold is a small set of seeds: the key that decrypts the secrets and the keys that identify the hosts. Recovery succeeds or fails on whether those seeds survive.

Read the next section before relying on anything else in this document.

## There is no off-site copy of anything

The Hetzner account that held every backup this estate took is closed, and nothing replaced it ([ADR 0081](adr/0081-retire-the-hetzner-account.md)). Velero, the Longhorn backup target, the CloudNativePG Barman archiver and the etcd snapshot upload are all removed. Volume data, database data and etcd snapshots now live on the three nodes in one room and nowhere else.

A fire, a theft or a flood therefore takes the cluster and every copy of its data in the same event, and no procedure in this document recovers from that. The intended replacement is a NAS in the rack, which is chosen but not bought and has no date. Until it exists, this is what the estate does and does not survive:

| Scenario | Recoverable | Mechanism |
| --- | --- | --- |
| One disk lost | Yes | Longhorn holds three replicas of every volume on the retain storage class, and rebuilds the lost one |
| One node lost | Yes | Volumes have replicas elsewhere, workloads reschedule, and the Postgres primary fails over in about 30 seconds |
| Anything declared in this repository | Yes | Flux reconciles it back. This is most of the estate |
| Any cluster Secret | Yes | Held as SOPS ciphertext in the private `bedrock-secrets` repository, given the age key |
| master's disk lost, taking etcd | Only from a snapshot copied off master beforehand | K3s writes its snapshots to the same disk as the datastore, so the failure that loses one loses the other |
| A volume deleted or corrupted in place | Only for the volumes the snapshot job covers, and only back to the last nightly snapshot | The `snapshot` RecurringJob is scoped to the `default` recurring-job group, which covers 6 of the cluster's 19 volumes: the four paperless volumes, open-webui and home-assistant-config. The three postgres volumes carry the same job through a direct label instead of the group, covering 9 volumes in total. Paperless-ai, grafana, minio, pgadmin, ollama, kiwix-library, data-zot-0, loki, tempo and prometheus carry no such label and have no snapshot at all. Where it runs, the job takes a snapshot at 03:30 and `snapshot-prune` retains the last 7; replication alone copies the write to all three replicas and cannot undo it. A postgres snapshot is crash-consistent only, recoverable through CloudNativePG's own WAL replay on the common restart-after-crash path but not to an arbitrary point inside a lost transaction ([ADR 0057](adr/0057-cnpg-barman-dr-and-velero-scope.md)) |
| A Postgres logical fault, a bad migration, a dropped table | Up to 24 hours if caught the same day, none beyond a week | Point-in-time recovery went with Barman, so nothing replays the write-ahead log to an arbitrary moment. The postgres volumes carry the `snapshot` job directly, so a revert to 03:30 is possible, but it is crash-consistent, rolls back all three instances together, and loses every write since ([ADR 0057](adr/0057-cnpg-barman-dr-and-velero-scope.md)) |
| Loss of the building | No | Nothing is off-site |

Two of those rows are worth acting on rather than reading. Copying a recent etcd snapshot off master by hand is the only thing standing between a master disk failure and a rebuild from an empty cluster. And the cluster age key now exists only on the operator workstation and inside the cluster, because the Velero backup that captured `flux-system/sops-age` as a side effect is gone; escrowing it somewhere deliberate is the single highest-value manual step in this document.

## Recovery seeds

These cannot live in the repository and must be kept somewhere that survives the loss of the cluster.

| Seed | What it is | Why it is not in Git |
| --- | --- | --- |
| Cluster age private key | The private half of the SOPS recipient, held in the cluster as the `sops-age` secret in `flux-system`. | It decrypts every committed secret. Only the public recipient is in `.sops.yaml`. |
| Host SSH private keys | `/etc/ssh/ssh_host_ed25519_key` on each node. | agenix encrypts host secrets to these. A fresh node generates new keys and cannot decrypt until they are restored or the secrets are re-keyed. |
| K3s server token | 141 bytes, delivered by agenix to `/run/agenix/k3s-token` on master, from `secrets/k3s-token.age`. | K3s derives the cluster CA material and, because `--secrets-encryption` is enabled, the AES keys in `encryption-config.json` from this token, and stores them inside etcd. An etcd snapshot restored under a different token produces a cluster whose Secrets cannot be decrypted, and it fails silently at restore time rather than erroring. |
| The repository | This repository, or a fork. | Flux syncs from it and the rebuild reads it. |
| The secrets repository | The private `bedrock-secrets` repository. | Holds every cluster Secret as SOPS ciphertext ([ADR 0060](adr/0060-private-secrets-repo-per-cluster-keys.md)). Encrypted, but the cluster cannot be reconstituted without it. |
| Operator identity | The admin SSH key, a recipient on every agenix secret. | Needed to re-key host secrets when host keys are lost. |

There is no backup-data seed. Nothing outside the cluster holds cluster data, which is the whole of [ADR 0081](adr/0081-retire-the-hetzner-account.md).

An etcd snapshot copied off master by hand is the closest thing to one, and it is worth treating as a seed while it exists. It carries the cluster CA material and every Secret, so it belongs wherever the age key belongs rather than on a convenient share.

External account tokens for Cloudflare and Tailscale are stored as SOPS secrets, so they return once the age key is present, but the accounts and their issuers live outside the repository.

## Reconciliation order

Flux applies the cluster in dependency order, and a layer whose dependencies are not ready waits rather than failing:

1. `cluster-sources` and `cluster-namespaces` have no dependencies. Sources defines the HelmRepositories every release pulls from; namespaces are created before anything lands in them.
2. `cluster-secrets` decrypts the SOPS secrets once the namespaces exist. It is the only Kustomization whose source is the `bedrock-secrets` repository rather than this one. `cluster-bootstrap-secrets` sits alongside it and carries the deploy key that makes that second source readable.
3. The platform layer follows, each part waiting on sources, secrets and namespaces rather than on one another: `cluster-cert-manager`, `cluster-storage`, `cluster-edge-onprem`, `cluster-security`, `cluster-observability`, `cluster-cnpg-operator`, `cluster-delivery`, `cluster-minio`, `cluster-notifications`, `cluster-alloy`, `cluster-rancher`. `cluster-flux-operator` and `cluster-coredns` depend on sources alone.
4. A second tier waits on specific parts of the first: `cluster-cnpg-db` on `cluster-cnpg-operator`, `cluster-issuers` on `cluster-cert-manager`, `cluster-metallb` on `cluster-edge-onprem`, `cluster-policies` on `cluster-security`, `cluster-flux` on `cluster-flux-operator`.
5. `cluster-apps` creates one Kustomization per application ([ADR 0066](adr/0066-standardize-app-delivery-per-app-kustomizations.md)). Each waits on `cluster-edge-onprem`, and those backed by Postgres also wait on `cluster-cnpg-db`.

## Full rebuild from total loss

The order matters: network, then hosts, then K3s, then Flux, then the age key. Every `nixos-rebuild` here points `--build-host` at the target itself, because no other machine exists yet and a workstation cannot produce a Linux closure; see [Rebuilding a host](../README.md#rebuilding-a-host).

1. Recover the seeds above: the age key, the repository, the host keys if they were kept, and a bootable NixOS installer.
2. Router first, in two steps. The `router-installer` SD image is a bare bootable Pi with SSH and the operator key: no VLANs, no DHCP, no DNS and no gateway, because `kea` and `adguardhome` are absent from it and `netdevs` is empty. Flash it, reach the Pi on whatever address the upstream network hands it, then push the real configuration, which is what brings up the network:

   ```
   nixos-rebuild switch --flake .#router --target-host root@<ip> --build-host root@<ip>
   ```

   Expect this build to be slow on the Pi. Until it completes there is no VLAN 20, so nothing else can start.
3. Hosts. Get a minimal NixOS with SSH onto each node, then push its configuration:

   ```
   nixos-rebuild switch --flake .#master --target-host root@<ip> --build-host root@<ip>
   ```

   `disko` wipes and formats the disk. Two recovery details: master's `hardware-configuration.nix` pins filesystem UUIDs that go stale after a wipe and must be regenerated, and agenix needs the original host SSH keys restored, or the secrets re-keyed to the new host keys (see Secret recovery), before the K3s join token can decrypt.
4. K3s. The master starts first and initializes etcd through `clusterInit`. The workers join it through the static `10.20.0.10` host entry and the shared token, so the join does not depend on router DNS. This yields an empty three-node cluster.
5. Flux. Seed it once against the repository:

   ```
   flux bootstrap github --owner <user> --repository <repo> --path kubernetes/clusters/home --personal
   ```

   The Flux Operator then adopts the install in place and carries it as a `FluxInstance` ([ADR 0037](adr/0037-flux-operator-controlplane-install.md)).
6. Age key. Create the `sops-age` secret in `flux-system` from the recovered key. This unblocks `cluster-secrets`:

   ```
   kubectl -n flux-system create secret generic sops-age --from-file=age.agekey=<keyfile>
   ```
7. Reconcile. Flux works through the order above and rebuilds the platform and the apps. Nothing else is applied by hand.
8. Data, such as it is. There is no restore step, because there is nothing off-cluster to restore from. What returns depends entirely on whether the disks survived:

   - If the node disks survived and only the operating systems were rebuilt, Longhorn reattaches its replicas and the volumes come back with them. This is the common case and the one the rebuild is really designed for.
   - If the disks were wiped, every volume is gone. The workloads recreate empty ones on first attach, and the data they held is not recoverable.
   - Postgres has no backup at all. If its volumes are gone, the databases behind Authentik, Paperless, Miniflux and Open WebUI come up empty and recreate their schemas on first boot, exactly as they did at the CloudNativePG cutover ([ADR 0046](adr/0046-cloudnative-pg-declarative-postgres.md)). Application state held in them is lost.
   - kiwix is the one workload that recovers cleanly from nothing. Its ZIM files are re-downloaded by an idempotent init container, so its recovery is a download rather than a restore.

   If an etcd snapshot was copied off master beforehand, restoring it is a separate decision rather than a step here. See the next section.
9. Admission. Reapply the `rancher-webhook` replica count and anti-affinity, which the Rancher-owned chart exposes no value for. The command and reasoning are in the [admission break-glass runbook](admission-break-glass.md). Until applied, a single-replica webhook fails Secret writes cluster-wide when its node is lost.
10. Verify DNS and the Cloudflare tunnel, certificate issuance, ingress, and the app set.

## Restoring etcd from a snapshot

K3s snapshots etcd twelve-hourly to `/var/lib/rancher/k3s/server/db/snapshots` on master, keeping five. A snapshot restores the whole Kubernetes API state, including objects Flux would otherwise rebuild. It is the right tool when the API server holds state that cannot be reconciled back, and the wrong tool when the manifests alone would recover the cluster.

The snapshots share a disk with the datastore they protect, which is the coupling [ADR 0064](adr/0064-off-node-etcd-s3-snapshots.md) was written to remove and which returned when the upload was withdrawn. A snapshot only helps with a corrupted or mis-edited cluster, not with a failed disk, unless a copy was taken off master first:

```
scp root@10.20.0.10:/var/lib/rancher/k3s/server/db/snapshots/<snapshot> .
```

The server token governs the restore. Restoring a snapshot under a different token yields a cluster that starts, serves, and returns ciphertext for every Secret, without erroring at restore time. Recover the token from `secrets/k3s-token.age` first and confirm it was in force when the snapshot was taken.

```
k3s etcd-snapshot ls
```

Restore on master, which becomes the sole etcd member:

```
systemctl stop k3s
k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot> \
  --secrets-encryption
```

`--secrets-encryption` must be passed here too, or the API server starts without the encryption provider and cannot read what it restored.

The command exits once the reset completes. Start k3s normally, then rejoin the workers, because `--cluster-reset` drops every peer. Verify by reading a Secret rather than listing objects: `kubectl -n flux-system get secret sops-age -o jsonpath='{.data}'` returning decodable data proves the token, the encryption config and the snapshot all agree.

Rehearsing this is hazardous. A restored snapshot contains the live estate's MetalLB pools, Flux sources, cert-manager issuers and CNPG cluster. A rehearsal host on VLAN 20 will therefore claim the same load balancer addresses and reconcile against the live repository. Rehearse only on an isolated host started with `--disable-agent`, so no kubelet registers and no workload runs, and with no route to VLAN 20. Treat that host as holding production secrets and destroy it afterwards.

## Live objects the backup removal leaves behind

Withdrawing the backup stack is not entirely expressible in Git. Three cleanups need a command, and two of them have an ordering constraint that cannot be recovered from cheaply if it is missed.

**Sequence the push ahead of the account closure.** The `hetzner` ProviderConfig carries the finalizer `horizon.dev/provider-config`, set by the running horizon operator rather than by any manifest. Flux prunes the object when the removal lands, but Kubernetes holds it in `Terminating` until the operator clears that finalizer, and the operator's teardown releases leases against the hcloud API before giving up ownership ([ADR 0071](adr/0071-deploy-horizon-operator-from-published-chart.md)). If the credential is already dead at that moment, the finalizer never clears and the object hangs indefinitely. Push and let the cluster reconcile before revoking account access. If it is ever found stuck, clear the finalizer by hand:

```
kubectl patch providerconfig hetzner --type=json -p '[{"op":"remove","path":"/metadata/finalizers"}]'
```

**Delete the Longhorn BackupTarget.** It carries `kustomize.toolkit.fluxcd.io/prune: disabled` and the finalizer `longhorn.io`, so removing its manifest leaves the live object in place, polling dead object storage every five minutes. It is the same finalizer shape as the ProviderConfig above, and it is not known whether `longhorn-manager` needs to reach the S3 endpoint to clear it. Run this deletion inside the same window as the push, while Hetzner still answers, not afterwards:

```
kubectl -n longhorn-system delete backuptarget default
```

Longhorn's backup records are hierarchical, so a cleanup that goes further deletes the parent `BackupVolume` rather than individual `Backup` resources. The parent re-syncs its children from the object store, and deleting children alone never converges.

**Delete the orphaned CloudNativePG backups.** The `ScheduledBackup` used `backupOwnerReference: self`, so its 58 `backups.postgresql.cnpg.io` objects in the `postgres` namespace outlive the schedule that created them and are not garbage-collected:

```
kubectl -n postgres delete backups.postgresql.cnpg.io --all
```

## Recovery objectives

Derived from the mechanisms as configured. They describe what the estate currently achieves, which is considerably less than it achieved before [ADR 0081](adr/0081-retire-the-hetzner-account.md).

| Data class | Mechanism | Recovery point | Recovery time |
| --- | --- | --- | --- |
| Postgres databases | Three-way volume replication and a quorum commit ([ADR 0068](adr/0068-cnpg-quorum-synchronous-replication.md)), plus a nightly `snapshot` job retaining 7 ([ADR 0057](adr/0057-cnpg-barman-dr-and-velero-scope.md)) | Zero for a lost disk or node; up to 24 hours for a logical fault caught the same day, none beyond a week, and crash-consistent rather than database-consistent | Automatic replica rebuild for a disk or a node; a manual revert to the snapshot and CloudNativePG's own WAL replay on restart, for a fault |
| Longhorn volumes | Three-way replication on the retain class, plus a nightly `snapshot` job retaining 7 for 9 of the cluster's 19 volumes: 6 through the `default` recurring-job group (the four paperless volumes, open-webui, home-assistant-config) and the three postgres volumes through a direct label | Zero for a lost disk or node on any volume; for a deletion or a corruption, up to 24 hours and none beyond a week on a covered volume, no recovery point at all on the other 10 | Automatic replica rebuild for a disk or a node; a manual revert to the snapshot for a deletion or a corruption, where a snapshot exists |
| Cluster API state | etcd snapshots every twelve hours, retain 5, on master's local disk | Up to 12 hours, and none at all if master's disk is what was lost | Under an hour on surviving hardware |
| Everything declared in Git | Flux reconciliation | Zero, the repository is the source of truth | Bounded by reconciliation, not by restore |
| Cluster Secrets | The private `bedrock-secrets` repository plus the age key | Zero | Minutes |
| Total cluster loss with the disks intact | The above, plus hardware | Up to 12 hours for API state, zero for volumes | Eight to twenty hours with spare hardware on hand, indefinite without it |
| Loss of the building | None | Not recoverable | Not applicable |

Losing **master** is worse than the table implies: a full outage of both data and external access, lasting until master returns. CloudNativePG's instance manager reads the Cluster resource from the Kubernetes API before starting Postgres, so with the single API server gone every database instance refuses to start regardless of which node holds the primary. MetalLB's speaker needs the API to see Services, so it stops announcing the load balancer address. Recovery once master boots is about five minutes. Losing either worker is a degradation: the primary fails over in around 30 seconds and ingress continues.

The recovery points assume the mechanisms work, and no restore has been proven, so the recovery times are estimates rather than measurements. In-cluster alerting also cannot detect total cluster loss: every alerting component runs on the same three nodes behind the same ingress.

## Secret recovery

Host secrets use agenix. Each `.age` file under `secrets/` is encrypted to the SSH host keys of the machines that need it, plus the operator key, and a node decrypts its own secrets at boot. `secrets/secrets.nix` lists which recipients can open each secret. If a host key is lost with the hardware, re-key:

1. Collect the new host key with `ssh-keyscan -t ed25519 <host>`, or read `/etc/ssh/ssh_host_ed25519_key.pub`.
2. Update the recipient in `secrets/secrets.nix`.
3. Re-encrypt with a currently valid identity: `agenix -r` re-keys everything, or `agenix -e secrets/<name>.age` re-keys one.
4. Commit and rebuild the host.

Cluster secrets use SOPS with age and live in the private `bedrock-secrets` repository ([ADR 0060](adr/0060-private-secrets-repo-per-cluster-keys.md)). Files matching `clusters/home/.*\.sops\.yaml` have their `data` and `stringData` encrypted to the recipient in that repository's `.sops.yaml`, and `cluster-secrets` decrypts them at apply time with the `sops-age` secret. Secrets are grouped under `bootstrap/`, `platform/`, `identity/`, and `apps/`, each with its own kustomization listing its files explicitly. Edit in place with `sops <path>`; add a new one by encrypting it and listing it in the folder kustomization.

The Velero and object-storage credentials were removed from that repository with the backup stack. The horizon and hcloud secrets under `bootstrap/` remain, and they carry credentials for an account that no longer exists, so they decrypt to values nothing consumes. The hcloud token among them is shared with the vigil project, so its cancellation affects that repository too.

Exactly one SOPS file remains in this repository, `kubernetes/clusters/home/bootstrap-secrets/bedrock-secrets-git-auth.sops.yaml`, carrying the read-only deploy key for the private repository and decrypted by the same cluster age key. That key is the only irreducible root: it opens the bootstrap secret, which opens the secrets repository, which holds everything else.

One secret sits outside both repositories by design: the Rancher `cattle-system/bootstrap-secret`, which is generated by the chart on first install.

## Tailscale overlay recovery

Master, worker-1, and worker-2 join the tailnet as `tag:cluster` devices, and flannel binds to `tailscale0` on all four cluster nodes ([ADR 0074](adr/0074-home-nodes-on-the-tailnet.md)). Three maintenance steps follow from that.

A rebuilt host can carry a stale `/var/lib/tailscale/tailscaled.state` from an earlier installation that pointed at a different control server. `tailscaled` loads those preferences, sits in `NoState` reaching for a server that no longer exists, and `tailscaled-autoconnect` fails on its 90 second timeout. Move the state file aside before the rebuild to clear it. Any node rebuilt from an installation that ever pointed at a different control server needs the same step.

`tailscaled.service` restarts on a NixOS activation that changes it, taking the tunnel interface with it and orphaning `flannel.1`, which stays bound to an interface that no longer exists and is not recreated automatically. After a Tailscale package bump, check each node's `flannel.alpha.coreos.com/public-ip` annotation and delete `flannel.1` on any node where it has drifted, to force a rebind.

The three Tailscale auth keys minted for this join, one per home node, are reusable rather than single-use and are valid until 3 November. Revoke each once its node has enrolled, which is what restores the one-key-one-node property the per-host split is meant to provide. This does not apply to the Pi router's own key, which was not minted for this join.

No burst node can join the tailnet, because no provider is configured for horizon to lease one from ([ADR 0081](adr/0081-retire-the-hetzner-account.md)). The `tag:burst` guidance in [ADR 0073](adr/0073-generic-burst-node-image.md) applies only if that changes.

## Rehearsing recovery without an outage

These checks validate the chain on a schedule, without destructively touching the live cluster. Entries move from untested to a date only when a drill has run.

| Mechanism | Last proven | Result |
| --- | --- | --- |
| Age key decrypts a committed secret | 2026-07-25 | Passed |
| Host configurations build | 2026-07-25 | Passed in CI |
| A scheduled etcd snapshot lands on master's disk | never | Untested. The 2026-07-25 check proved a manual snapshot reaching object storage, a path that no longer exists |
| etcd snapshot restores | never | Untested |
| Longhorn replica rebuild after a node loss | never | Untested as a drill. Node-loss behaviour was measured on 2026-07-26 |
| Re-key to new host keys | never | Untested |
| Fresh-cluster GitOps bootstrap | never | Untested |

There is no backup-restore row, because there is no backup to restore.

- Age key decrypts. `sops -d` of a committed secret succeeds with the operator key.
- Host configurations build. `nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath` for each host, or `nixos-rebuild build`.
- Re-key works. Decrypt a host secret with the operator identity, re-encrypt it to a freshly generated key, and decrypt with the new key.
- A scheduled snapshot lands. `k3s etcd-snapshot ls` on master lists a file newer than twelve hours. This is the cheapest check in the table and the only one covering the estate's sole remaining point-in-time mechanism.
- Fresh-cluster GitOps bootstrap. On a throwaway cluster such as `kind`, install Flux, create the `sops-age` secret from the operator key, point a GitRepository at this repository, and reconcile a SOPS-decrypting Kustomization. The secrets materializing as live Secrets proves the bootstrap and decryption path end to end. The full app set does not reconcile on unlike hardware, because the manifests assume the home storage, load balancer, addressing and overlay.

## Known gaps

- Nothing is held off-site. This is the largest gap and it is deliberate, recorded in [ADR 0081](adr/0081-retire-the-hetzner-account.md). It closes when the NAS is bought and exposes S3-compatible storage, and not before.
- Postgres has no point-in-time recovery and no database-consistent backup. A bad migration, a dropped table or a corrupted index reaches all three replicas at once, and the only way back is a crash-consistent revert to the last nightly snapshot, which loses every write since and is not possible at all once the fault is older than the retained week.
- Longhorn snapshots go back one week at most. The `snapshot` job creates one nightly and `snapshot-prune` keeps the last 7; a deletion or a corruption noticed later than that has nothing to revert to. This is a local point-in-time position, not a backup: it lives on the same three replicas as the data it protects, so it is worth nothing against the loss of a disk beyond what replication already covers, and nothing at all against the loss of the cluster or the building.
- Etcd snapshots share a disk with the datastore they protect. Copying one off master by hand is the only mitigation in place, and nothing performs or checks that copy.
- `/var/lib/rancher/k3s/server/db/snapshots` on master should be treated as a credential store rather than as backup data. Each snapshot carries the cluster CA material and every Secret, and its confidentiality rests on the server token rather than on the file's location.
- No restore has ever been performed, for any mechanism. The node-loss figures were measured on 2026-07-26; everything else is an estimate.
- The `snapshot` recurring job covers only 9 of the 19 Longhorn volumes. Six join through the `default` recurring-job group (the four paperless volumes, open-webui and home-assistant-config), and the three postgres volumes join through a direct label instead of the group. Paperless-ai, Grafana's SQLite, MinIO, pgAdmin, Ollama, kiwix-library, data-zot-0, loki, tempo and prometheus have no snapshot at all. This is a live gap in the mechanism that exists now, not a historical one, and the coverage question should be settled deliberately rather than inherited.
- Alertmanager cannot recover from a node loss on its own. It has no PersistentVolumeClaim, so Longhorn's `nodeDownPodDeletionPolicy` does not cover it, and nothing force-deletes the pod stranded on an unreachable node. Alert evaluation returns after about 16 minutes when Prometheus is force-deleted and rescheduled; alert delivery stays down until the node returns or the pod is deleted by hand.
- worker-2 cannot be drained while it holds the only replica of a volume. Longhorn's `block-if-contains-last-replica` policy correctly refuses, so the node is not patchable without moving `data-zot-0` and `kiwix-library` to a replicated class or forcing the drain.
- A mass reschedule can outlast the event that caused it. Draining master took 38 seconds and the estate took 45 minutes to settle, because every rescheduled pod pulled images through the registry cache at once and containerd does not fall back to the upstream registry when the mirror is merely slow.
- The `rancher-webhook` replica count and anti-affinity are imperative and are not reconciled, so a rebuild returns to a single replica until step 9 is reapplied.
- The age key is held only on the operator's workstation, by choice. It is simultaneously the SOPS recovery identity and the SSH credential for all four hosts, so losing that machine loses access and decryption in the same event. The Velero backup that used to capture `flux-system/sops-age` as a side effect is gone, so there is no accidental second copy any more.
- kiwix is deliberately not backed up, and now it is in the same position as everything else. Its 32 GB of ZIM files are re-downloaded from `download.kiwix.org` by an idempotent init container, which makes it the one workload whose recovery story is unaffected by the loss of the backup stack.
- master's pinned filesystem UUIDs must be regenerated after a disk wipe.
- Until [ADR 0074](adr/0074-home-nodes-on-the-tailnet.md), the operator had no remote management path that survived the Pi. Every route to VLAN 20 ran through it, and the SSH jump host named in `./CLAUDE.md` was not an alternative, because port 22 was opened on `vlan20` only and `end0` is not a trusted interface, so that jump host was reachable solely over the tunnel it would be replacing. From the home LAN the router forwards nothing into VLAN 20 except the service VIP on 80 and 443. This was hit on 2026-07-26: tailscaled on the Pi kept its coordination-server session while passing no WireGuard traffic, so the Tailscale app still showed the router online while the estate was unreachable, and recovery needed a physical power cycle. The cluster itself was unaffected throughout. That gap is closed now: master joins the tailnet directly as its own `tag:cluster` device with a per-host auth key, and `hosts/common/networking.nix` opens port 22 on every interface rather than on `vlan20` alone, so an operator reaches master over its own WireGuard session without transiting the Pi's subnet router or depending on the Pi's `tailscaled` state at all. A repeat of the 2026-07-26 failure, the Pi's `tailscaled` wedged while still claiming to be online, no longer strands the estate. The one thing still Pi-mediated is master's own outbound DNS resolution, since its client keeps `--accept-dns=false` and the Pi as resolver; that affects traffic master initiates, not an operator reaching master.
- A full bare-metal rehearsal, re-imaging spare hardware end to end, and a full reconcile on unlike hardware both depend on a cluster-appropriate overlay that does not exist yet.

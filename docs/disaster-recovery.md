# Disaster recovery

How to rebuild the cluster from nothing, what has to survive outside it, and how to rehearse the recovery without causing an outage.

GitOps reconciles everything declared in this repository, so recovery is mostly a matter of reapplying it. What the repository cannot hold is a small set of seeds: the key that decrypts the secrets, the keys that identify the hosts, and the backup data itself. Recovery succeeds or fails on whether those seeds survive.

## Recovery seeds

These cannot live in the repository and must be kept somewhere that survives the loss of the cluster.

| Seed | What it is | Why it is not in Git |
| --- | --- | --- |
| Cluster age private key | The private half of the SOPS recipient, held in the cluster as the `sops-age` secret in `flux-system`. | It decrypts every committed secret. Only the public recipient is in `.sops.yaml`. |
| Host SSH private keys | `/etc/ssh/ssh_host_ed25519_key` on each node. | agenix encrypts host secrets to these. A fresh node generates new keys and cannot decrypt until they are restored or the secrets are re-keyed. |
| Backup data | Two Hetzner object-storage buckets and their credentials. `basalt-backups` holds the Velero backups under the `velero` prefix, every Longhorn volume backup, and the k3s etcd snapshots under `etcd-snapshots`. `basalt-cnpg-backups` holds the CloudNativePG base backups and archived WAL. | The only copy of cluster data. The buckets persist outside the cluster. |
| K3s server token | 141 bytes, delivered by agenix to `/run/agenix/k3s-token` on master, from `secrets/k3s-token.age`. | K3s derives the cluster CA material and, because `--secrets-encryption` is enabled, the AES keys in `encryption-config.json` from this token, and stores them inside etcd. An etcd snapshot restored under a different token produces a cluster whose Secrets cannot be decrypted, and it fails silently at restore time rather than erroring. |
| The repository | This repository, or a fork. | Flux syncs from it and the rebuild reads it. |
| The secrets repository | The private `bedrock-secrets` repository. | Holds every cluster Secret as SOPS ciphertext ([ADR 0060](adr/0060-private-secrets-repo-per-cluster-keys.md)). Encrypted, but the cluster cannot be reconstituted without it. |
| Operator identity | The admin SSH key, a recipient on every agenix secret. | Needed to re-key host secrets when host keys are lost. |

External account tokens for Hetzner, Cloudflare, and Tailscale are stored as SOPS secrets, so they return once the age key is present, but the accounts and their issuers live outside the repository.

## Reconciliation order

Flux applies the cluster in dependency order, and a layer whose dependencies are not ready waits rather than failing:

1. `cluster-sources` and `cluster-namespaces` have no dependencies. Sources defines the HelmRepositories every release pulls from; namespaces are created before anything lands in them.
2. `cluster-secrets` decrypts the SOPS secrets once the namespaces exist. It is the only Kustomization whose source is the `bedrock-secrets` repository rather than this one. `cluster-bootstrap-secrets` sits alongside it and carries the deploy key that makes that second source readable.
3. The platform layer follows, each part waiting on sources, secrets and namespaces rather than on one another: `cluster-cert-manager`, `cluster-storage`, `cluster-edge-onprem`, `cluster-security`, `cluster-observability`, `cluster-cnpg-operator`, `cluster-delivery`, `cluster-minio`, `cluster-notifications`, `cluster-alloy`, `cluster-rancher`. `cluster-flux-operator` and `cluster-coredns` depend on sources alone.
4. A second tier waits on specific parts of the first: `cluster-cnpg-db` on `cluster-cnpg-operator`, `cluster-issuers` on `cluster-cert-manager`, `cluster-metallb` on `cluster-edge-onprem`, `cluster-policies` on `cluster-security`, `cluster-flux` on `cluster-flux-operator`.
5. `cluster-apps` creates one Kustomization per application ([ADR 0066](adr/0066-standardize-app-delivery-per-app-kustomizations.md)). Each waits on `cluster-edge-onprem`, and those backed by Postgres also wait on `cluster-cnpg-db`.

## Full rebuild from total loss

The order matters: network, then hosts, then K3s, then Flux, then the age key, then data. Every `nixos-rebuild` here points `--build-host` at the target itself, because no other machine exists yet and a workstation cannot produce a Linux closure; see [Rebuilding a host](../README.md#rebuilding-a-host).

1. Recover the seeds above: the age key, the Hetzner bucket and its credentials, the repository, the host keys if they were backed up, and a bootable NixOS installer.
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
8. Data, in two parts. Velero restores the objects Git cannot reconstruct, which is Secrets and the PersistentVolumeClaim and PersistentVolume bindings:

   ```
   velero restore create --from-backup <latest-daily-dr>
   ```

   Volume contents come from Longhorn, not from Velero. `longhorn-snapshot-vsc` sets `type: snap`, so the CSI path Velero uses takes a local Longhorn snapshot, which does not survive the loss of the cluster. The off-site copy of every volume in the `default` group is the Longhorn backup taken nightly at 03:30 with a retain of 30, restored through the Longhorn UI or a `Volume` with `fromBackup` set. `freeze-filesystem-for-snapshot` is on, so the snapshot each backup is taken from is filesystem-consistent rather than crash-consistent. Postgres is separate again and comes from Barman.

   The `daily-dr` schedule runs at 02:00, so up to a day of object state is at risk.
9. Admission. Reapply the `rancher-webhook` replica count and anti-affinity, which the Rancher-owned chart exposes no value for. The command and reasoning are in the [admission break-glass runbook](admission-break-glass.md). Until applied, a single-replica webhook fails Secret writes cluster-wide when its node is lost.
10. Verify DNS and the Cloudflare tunnel, certificate issuance, ingress, and the app set.

## Restoring etcd from a snapshot

K3s snapshots etcd twelve-hourly to `s3://basalt-backups/etcd-snapshots/`, keeping five. A snapshot restores the whole Kubernetes API state, including objects Flux would otherwise rebuild. It is the right tool when the API server holds state that cannot be reconciled back, and the wrong tool when the manifests alone would recover the cluster.

The server token governs this procedure. Restoring a snapshot under a different token yields a cluster that starts, serves, and returns ciphertext for every Secret, without erroring at restore time. Recover the token from `secrets/k3s-token.age` first and confirm it was in force when the snapshot was taken.

```
k3s etcd-snapshot ls
k3s etcd-snapshot ls --s3
```

Restore on master, which becomes the sole etcd member:

```
systemctl stop k3s
k3s server \
  --cluster-reset \
  --cluster-reset-restore-path=/var/lib/rancher/k3s/server/db/snapshots/<snapshot> \
  --secrets-encryption
```

`--secrets-encryption` must be passed here too, or the API server starts without the encryption provider and cannot read what it restored. To pull the snapshot straight from object storage, add `--etcd-s3 --etcd-s3-bucket=basalt-backups --etcd-s3-region=eu-central-1 --etcd-s3-endpoint=hel1.your-objectstorage.com --etcd-s3-folder=etcd-snapshots`, with the credentials from `/run/agenix/etcd-s3-credentials`.

The command exits once the reset completes. Start k3s normally, then rejoin the workers, because `--cluster-reset` drops every peer. Verify by reading a Secret rather than listing objects: `kubectl -n flux-system get secret sops-age -o jsonpath='{.data}'` returning decodable data proves the token, the encryption config and the snapshot all agree.

Rehearsing this is hazardous. A restored snapshot contains the live estate's MetalLB pools, Flux sources, Longhorn backup target, cert-manager issuers and CNPG cluster. A rehearsal host on VLAN 20 will therefore claim the same load balancer addresses, reconcile against the live repository, and archive WAL into the live object-storage path. Rehearse only on an isolated host started with `--disable-agent`, so no kubelet registers and no workload runs, and with no route to VLAN 20. Treat that host as holding production secrets and destroy it afterwards.

## Recovery objectives

Derived from the mechanisms as configured. They describe what the estate currently achieves.

| Data class | Mechanism | Recovery point | Recovery time |
| --- | --- | --- | --- |
| Postgres databases | CloudNativePG base backups daily at 03:00 with continuous WAL archiving to `basalt-cnpg-backups`, 30 day retention | About five minutes, bounded by WAL shipping | Restore into a new cluster, minutes to hours depending on replay distance |
| Longhorn volumes | Recurring job nightly at 03:30, retain 30 | Up to 24 hours | Minutes per volume |
| Cluster API state | etcd snapshots every twelve hours, retain 5, uploaded to `basalt-backups` | Up to 12 hours | Under an hour on surviving hardware |
| Kubernetes objects | Velero daily at 02:00, 168 hour TTL, scoped to Secrets and PVC or PV bindings | Up to 24 hours | Minutes per namespace |
| Everything declared in Git | Flux reconciliation | Zero, the repository is the source of truth | Bounded by reconciliation, not by restore |
| Total cluster loss | All of the above, plus hardware | The worst of the above, so up to 24 hours | Eight to twenty hours with spare hardware on hand, indefinite without it |

Losing **master** is worse than the table implies: a full outage of both data and external access, lasting until master returns. CloudNativePG's instance manager reads the Cluster resource from the Kubernetes API before starting Postgres, so with the single API server gone every database instance refuses to start regardless of which node holds the primary. MetalLB's speaker needs the API to see Services, so it stops announcing the load balancer address. Recovery once master boots is about five minutes. Losing either worker is a degradation: the primary fails over in around 30 seconds and ingress continues.

The recovery points assume the mechanisms work, and no restore has been proven, so the recovery times are estimates rather than measurements. In-cluster alerting also cannot detect total cluster loss: every alerting component runs on the same three nodes behind the same ingress.

## Secret recovery

Host secrets use agenix. Each `.age` file under `secrets/` is encrypted to the SSH host keys of the machines that need it, plus the operator key, and a node decrypts its own secrets at boot. `secrets/secrets.nix` lists which recipients can open each secret. If a host key is lost with the hardware, re-key:

1. Collect the new host key with `ssh-keyscan -t ed25519 <host>`, or read `/etc/ssh/ssh_host_ed25519_key.pub`.
2. Update the recipient in `secrets/secrets.nix`.
3. Re-encrypt with a currently valid identity: `agenix -r` re-keys everything, or `agenix -e secrets/<name>.age` re-keys one.
4. Commit and rebuild the host.

Burst nodes do not use agenix; their join token and server address arrive through provisioning metadata.

Cluster secrets use SOPS with age and live in the private `bedrock-secrets` repository ([ADR 0060](adr/0060-private-secrets-repo-per-cluster-keys.md)). Files matching `clusters/home/.*\.sops\.yaml` have their `data` and `stringData` encrypted to the recipient in that repository's `.sops.yaml`, and `cluster-secrets` decrypts them at apply time with the `sops-age` secret. Secrets are grouped under `bootstrap/`, `platform/`, `identity/`, and `apps/`, each with its own kustomization listing its files explicitly. The Hetzner token in `bootstrap/hcloud.sops.yaml` is shared with the vigil project, so rotation must be coordinated across both. Edit in place with `sops <path>`; add a new one by encrypting it and listing it in the folder kustomization.

Exactly one SOPS file remains in this repository, `kubernetes/clusters/home/bootstrap-secrets/bedrock-secrets-git-auth.sops.yaml`, carrying the read-only deploy key for the private repository and decrypted by the same cluster age key. That key is the only irreducible root: it opens the bootstrap secret, which opens the secrets repository, which holds everything else.

One secret sits outside both repositories by design: the Rancher `cattle-system/bootstrap-secret`, which is generated by the chart on first install.

The `cnpg-backup-s3` secret backing CloudNativePG's Barman archiving ([ADR 0057](adr/0057-cnpg-barman-dr-and-velero-scope.md)) is not created by any reconciler. It carries the keys `ACCESS_KEY_ID` and `ACCESS_SECRET_KEY`, is SOPS-encrypted, and is written to `kubernetes/clusters/home/secrets/apps/cnpg-backup-s3.sops.yaml` in namespace `postgres`, added to that directory's kustomization before the change is pushed. Without it the archiver cannot authenticate.

## Tailscale overlay recovery

Master, worker-1, and worker-2 join the tailnet as `tag:cluster` devices, and flannel binds to `tailscale0` on all four cluster nodes ([ADR 0074](adr/0074-home-nodes-on-the-tailnet.md)). Three maintenance steps follow from that.

A rebuilt host can carry a stale `/var/lib/tailscale/tailscaled.state` from an earlier installation that pointed at a different control server. `tailscaled` loads those preferences, sits in `NoState` reaching for a server that no longer exists, and `tailscaled-autoconnect` fails on its 90 second timeout. Move the state file aside before the rebuild to clear it. Any node rebuilt from an installation that ever pointed at a different control server needs the same step.

`tailscaled.service` restarts on a NixOS activation that changes it, taking the tunnel interface with it and orphaning `flannel.1`, which stays bound to an interface that no longer exists and is not recreated automatically. After a Tailscale package bump, check each node's `flannel.alpha.coreos.com/public-ip` annotation and delete `flannel.1` on any node where it has drifted, to force a rebind.

The three Tailscale auth keys minted for this join, one per home node, are reusable rather than single-use and are valid until 3 November. Revoke each once its node has enrolled, which is what restores the one-key-one-node property the per-host split is meant to provide. This does not apply to the Pi router's own key, which was not minted for this join.

Burst nodes rely on the same `tailscaled-autoconnect` unit at its systemd default of 90 seconds, wide enough for a Hetzner server to reach the coordination server ([ADR 0073](adr/0073-generic-burst-node-image.md)). If a burst node is ever seen failing that unit on timeout rather than on an authentication error, the timeout is the first thing to raise.

## Rehearsing recovery without an outage

These checks validate the chain on a schedule, without destructively touching the live cluster. Entries move from untested to a date only when a drill has run.

| Mechanism | Last proven | Result |
| --- | --- | --- |
| Age key decrypts a committed secret | 2026-07-25 | Passed |
| Host configurations build | 2026-07-25 | Passed in CI |
| etcd snapshot reaches object storage | 2026-07-25 | Passed for a manual snapshot only. No scheduled snapshot has yet been proven, because the schedule was broken between 2026-07-09 and 2026-07-25 |
| etcd snapshot restores | never | Untested |
| CloudNativePG point-in-time recovery | never | Untested |
| Velero restore | never | Untested. No `Restore` object has ever existed in this cluster |
| Longhorn volume restore | never | Untested |
| SQLite integrity after restore | never | Untested |
| Re-key to new host keys | never | Untested |
| Fresh-cluster GitOps bootstrap | never | Untested |

- Age key decrypts. `sops -d` of a committed secret succeeds with the operator key.
- Host configurations build. `nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath` for each host, or `nixos-rebuild build`.
- Re-key works. Decrypt a host secret with the operator identity, re-encrypt it to a freshly generated key, and decrypt with the new key.
- Backups restore. Restore a namespace into a temporary one and confirm the workload and any volume return:

  ```
  velero restore create drtest --from-backup <latest> \
    --include-namespaces <ns> --namespace-mappings <ns>:<ns>-drtest \
    --include-cluster-resources=false
  ```

  Three constraints narrow this. The `velero` CLI is not installed on the operator workstation, so the drill either installs it or applies a `Restore` object directly. `--include-cluster-resources=false` is not optional: a daily backup holds around 2800 objects including cluster-scoped ones, and restoring those would overwrite live CRDs, ClusterRoles and webhook configurations. And the target namespace must not be one whose workloads depend on a Kyverno `PolicyException`, because exceptions match on the original namespace name and do not follow a remap, so the restored pods are rejected at admission. `kiwix` is the correct drill target, holding a volume whose loss is already accepted as restore-by-redownload; `authentik`, `llm`, `minio`, `ntfy`, `paperless`, `postgres` and `reloader` are not.
- Fresh-cluster GitOps bootstrap. On a throwaway cluster such as `kind`, install Flux, create the `sops-age` secret from the operator key, point a GitRepository at this repository, and reconcile a SOPS-decrypting Kustomization. The secrets materializing as live Secrets proves the bootstrap and decryption path end to end. The full app set does not reconcile on unlike hardware, because the manifests assume the home storage, load balancer, addressing and overlay.

## Known gaps

- No restore has ever been performed, for any mechanism. The recovery times for the restore mechanisms are estimates; the node-loss figures were measured on 2026-07-26.
- Alertmanager cannot recover from a node loss on its own. It has no PersistentVolumeClaim, so Longhorn's `nodeDownPodDeletionPolicy` does not cover it, and nothing force-deletes the pod stranded on an unreachable node. Alert evaluation returns after about 16 minutes when Prometheus is force-deleted and rescheduled; alert delivery stays down until the node returns or the pod is deleted by hand.
- worker-2 cannot be drained while it holds the only replica of a volume. Longhorn's `block-if-contains-last-replica` policy correctly refuses, so the node is not patchable without moving `data-zot-0` and `kiwix-library` to a replicated class or forcing the drain.
- A mass reschedule can outlast the event that caused it. Draining master took 38 seconds and the estate took 45 minutes to settle, because every rescheduled pod pulled images through the registry cache at once and containerd does not fall back to the upstream registry when the mirror is merely slow.
- 2026-07-24 is a hole in every backup mechanism at once. Velero's run failed validation because the backup storage location was unavailable, no CloudNativePG base backup was taken, and Longhorn produced no backups. Point-in-time recovery across that day depends on WAL continuity that has not been verified.
- The `rancher-webhook` replica count and anti-affinity are imperative and are not reconciled, so a rebuild returns to a single replica until step 9 is reapplied.
- The age key is held only on the operator's workstation, by choice. It is simultaneously the SOPS recovery identity and the SSH credential for all four hosts, so losing that machine loses access and decryption in the same event.
- `basalt-backups` holds the estate twice over, since an etcd snapshot contains the cluster CA material and every Secret, and the Velero backups include `flux-system/sops-age`. It should be treated as a credential store rather than as backup data.
- Three writers hold delete rights on `basalt-backups` with no object lock and no coordination between their retention policies.
- The `cnpg-backup-s3` key pair is not actually scoped to the CNPG bucket alone. Hetzner key pairs are project-wide by default and no bucket policy exists, so it, and every other project key, carries `FULL_CONTROL` over both `basalt-backups` and `basalt-cnpg-backups`. Scoping it needs a bucket policy naming the access key, a console action not yet taken.
- kiwix is deliberately not backed up. Its 32 GB of ZIM files are re-downloaded from `download.kiwix.org` by an idempotent init container, so recovery is a redownload rather than a restore. Its backups previously failed at 85 percent anyway.
- Fifteen orphaned Longhorn `BackupVolume` objects remain for PVCs that no longer exist and will never be pruned. One of them holds the only surviving backup of the ollama volume.
- master's pinned filesystem UUIDs must be regenerated after a disk wipe.
- Until [ADR 0074](adr/0074-home-nodes-on-the-tailnet.md), the operator had no remote management path that survived the Pi. Every route to VLAN 20 ran through it, and the SSH jump host named in `./CLAUDE.md` was not an alternative, because port 22 was opened on `vlan20` only and `end0` is not a trusted interface, so that jump host was reachable solely over the tunnel it would be replacing. From the home LAN the router forwards nothing into VLAN 20 except the service VIP on 80 and 443. This was hit on 2026-07-26: tailscaled on the Pi kept its coordination-server session while passing no WireGuard traffic, so the Tailscale app still showed the router online while the estate was unreachable, and recovery needed a physical power cycle. The cluster itself was unaffected throughout. That gap is closed now: master joins the tailnet directly as its own `tag:cluster` device with a per-host auth key, and `hosts/common/networking.nix` opens port 22 on every interface rather than on `vlan20` alone, so an operator reaches master over its own WireGuard session without transiting the Pi's subnet router or depending on the Pi's `tailscaled` state at all. A repeat of the 2026-07-26 failure, the Pi's `tailscaled` wedged while still claiming to be online, no longer strands the estate. The one thing still Pi-mediated is master's own outbound DNS resolution, since its client keeps `--accept-dns=false` and the Pi as resolver; that affects traffic master initiates, not an operator reaching master.
- A full bare-metal rehearsal, re-imaging spare hardware end to end, and a full reconcile on unlike hardware both depend on a cluster-appropriate overlay that does not exist yet.

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

The age private key is held only on the operator's workstation, by choice. That is an accepted single point of failure: if both the workstation and the cluster are lost, the encrypted secrets are unrecoverable and must be reissued from their sources.

## Reconciliation order

Flux applies the cluster in dependency order, and a layer whose dependencies are not ready waits rather than failing:

1. `cluster-sources` and `cluster-namespaces` have no dependencies. Sources defines the HelmRepositories every release pulls from; namespaces are created before anything lands in them.
2. `cluster-secrets` decrypts the SOPS secrets once the namespaces exist. It is the only Kustomization whose source is the `bedrock-secrets` repository rather than this one. `cluster-bootstrap-secrets` sits alongside it and carries the deploy key that makes that second source readable.
3. The platform layer follows, each part waiting on sources, secrets and namespaces rather than on one another: `cluster-cert-manager`, `cluster-storage`, `cluster-edge-onprem`, `cluster-security`, `cluster-observability`, `cluster-cnpg-operator`, `cluster-delivery`, `cluster-minio`, `cluster-notifications`, `cluster-alloy`, `cluster-rancher`. `cluster-flux-operator` and `cluster-coredns` depend on sources alone.
4. A second tier waits on specific parts of the first: `cluster-cnpg-db` on `cluster-cnpg-operator`, `cluster-issuers` on `cluster-cert-manager`, `cluster-metallb` on `cluster-edge-onprem`, `cluster-policies` on `cluster-security`, `cluster-flux` on `cluster-flux-operator`.
5. `cluster-apps` creates one Kustomization per application ([ADR 0066](adr/0066-standardize-app-delivery-per-app-kustomizations.md)). Each waits on `cluster-edge-onprem`, and those backed by Postgres also wait on `cluster-cnpg-db`.

There is no `cluster-infrastructure`, `cluster-networking` or `cluster-monitoring`. Earlier revisions of this document named them and they have never existed under those names.

## Full rebuild from total loss

The order matters: network, then hosts, then K3s, then Flux, then the age key, then data.

1. Recover the seeds above: the age key, the Hetzner bucket and its credentials, the repository, the host keys if they were backed up, and a bootable NixOS installer.
2. Router first. Flash the Pi from the `router-installer` SD image. It brings up the VLANs, DHCP, DNS, and the gateway that the rest of the network needs.
3. Hosts. Get a minimal NixOS with SSH onto each node, then push its configuration:

   ```
   nixos-rebuild switch --flake .#master --target-host root@<ip> --build-host root@<ip>
   ```

   `--build-host` points at the target itself because no other machine exists yet to build on, and without it the build runs on the workstation, which cannot produce a Linux closure. `disko` wipes and formats the disk. Two recovery details: master's `hardware-configuration.nix` pins filesystem UUIDs that go stale after a wipe and must be regenerated, and agenix needs the original host SSH keys restored, or the secrets re-keyed to the new host keys (see Secret recovery), before the K3s join token can decrypt.
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
8. Data. Velero reads the surviving bucket and restores the latest backup:

   ```
   velero restore create --from-backup <latest-daily-dr>
   ```

   The recovery point is the backup interval. The `daily-dr` schedule runs at 02:00, so up to a day of data is at risk.
9. Admission. Reapply the one setting Flux cannot carry, the `rancher-webhook` replica count and its anti-affinity, which the Rancher-owned chart exposes no value for. The command and the reasoning are in the [admission break-glass runbook](admission-break-glass.md). Until it is applied the cluster runs a single-replica webhook that fails Secret writes cluster-wide when its node is lost.
10. Verify DNS and the Cloudflare tunnel, certificate issuance, ingress, and the app set.

## Restoring etcd from a snapshot

K3s snapshots etcd on a twelve-hourly schedule and uploads each snapshot to `s3://basalt-backups/etcd-snapshots/`, keeping five. A snapshot restores the whole Kubernetes API state: every object, including the ones Flux would otherwise rebuild. It is the right tool when the API server has state that cannot be reconciled back, and the wrong tool when the manifests alone would recover the cluster.

The server token governs everything about this procedure. K3s stores the cluster CA material and, because `--secrets-encryption` is enabled, the AES keys from `encryption-config.json` inside etcd, keyed off the token. Restoring a snapshot under a different token yields a cluster that starts, serves, and returns ciphertext for every Secret. It does not error at restore time. Recover the token from `secrets/k3s-token.age` before touching a snapshot, and confirm it is the token that was in force when the snapshot was taken.

List what exists, locally and in object storage:

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

`--secrets-encryption` must be passed here as well, or the API server starts without the encryption provider and cannot read what it restored. To pull the snapshot straight from object storage instead of a local file, add `--etcd-s3 --etcd-s3-bucket=basalt-backups --etcd-s3-region=eu-central-1 --etcd-s3-endpoint=hel1.your-objectstorage.com --etcd-s3-folder=etcd-snapshots`, with the credentials from `/run/agenix/etcd-s3-credentials`.

The command exits once the reset completes. Start k3s normally afterwards, then rejoin the workers, because `--cluster-reset` drops every peer from the member list. Verify the restore by reading a Secret rather than by listing objects: `kubectl -n flux-system get secret sops-age -o jsonpath='{.data}'` returning decodable data proves the token, the encryption config and the snapshot all agree.

Rehearsing this without an outage requires care. A restored snapshot contains the live estate's MetalLB pools, Flux sources, Longhorn backup target, cert-manager issuers and CNPG cluster. A rehearsal host that runs a kubelet on VLAN 20 will therefore claim the same load balancer addresses, reconcile against the live repository, and archive WAL into the live object-storage path. Rehearse only on an isolated host started with `--disable-agent`, so no kubelet registers and no workload runs, and with no route to VLAN 20. Treat that host as holding production secrets and destroy it afterwards.

## Recovery objectives

Derived from the mechanisms as configured, not negotiated with anyone. They describe what the estate currently achieves.

| Data class | Mechanism | Recovery point | Recovery time |
| --- | --- | --- | --- |
| Postgres databases | CloudNativePG base backups daily at 03:00 with continuous WAL archiving to `basalt-cnpg-backups`, 30 day retention | About five minutes, bounded by WAL shipping | Restore into a new cluster, minutes to hours depending on replay distance |
| Longhorn volumes | Recurring job nightly at 03:30, retain 7 | Up to 24 hours | Minutes per volume |
| Cluster API state | etcd snapshots every twelve hours, retain 5, uploaded to `basalt-backups` | Up to 12 hours | Under an hour on surviving hardware |
| Kubernetes objects | Velero daily at 02:00, 168 hour TTL | Up to 24 hours | Minutes per namespace |
| Everything declared in Git | Flux reconciliation | Zero, the repository is the source of truth | Bounded by reconciliation, not by restore |
| Total cluster loss | All of the above, plus hardware | The worst of the above, so up to 24 hours | Eight to twenty hours with spare hardware on hand, indefinite without it |

One case is worse than the table implies. Losing **master** is a full outage of both data and external access, not a degradation, and it lasts until master returns. Failure injection on 2026-07-26 established why: CloudNativePG's instance manager reads the Cluster resource from the Kubernetes API before starting Postgres, so with the single API server gone every database instance refuses to start regardless of which node holds the primary; and MetalLB's speaker needs the API to see Services, so it stops announcing the load balancer address and nothing answers ARP for it. Recovery once master boots is about five minutes. Losing either worker is genuinely a degradation: the database primary fails over in around 30 seconds and ingress continues.

Two further caveats belong with these numbers. The recovery points assume the mechanisms are working, and no restore has yet been proven, so the recovery times are estimates rather than measurements. And in-cluster alerting cannot detect total cluster loss: every alerting component runs on the same three nodes behind the same ingress, so the failure that matters most is the one nothing will report.

## Secret recovery

Two mechanisms, recovered differently.

Host secrets use agenix. Each `.age` file under `secrets/` is encrypted to the SSH host keys of the machines that need it, plus the operator key, and a node decrypts its own secrets at boot. `secrets/secrets.nix` lists which recipients can open each secret. If a host key is lost with the hardware, re-key:

1. Collect the new host key with `ssh-keyscan -t ed25519 <host>`, or read `/etc/ssh/ssh_host_ed25519_key.pub`.
2. Update the recipient in `secrets/secrets.nix`.
3. Re-encrypt with a currently valid identity: `agenix -r` re-keys everything, or `agenix -e secrets/<name>.age` re-keys one.
4. Commit and rebuild the host.

Burst nodes do not use agenix; their join token and server address arrive through provisioning metadata.

Cluster secrets use SOPS with age and live in the separate private `bedrock-secrets` repository, not in this one ([ADR 0060](adr/0060-private-secrets-repo-per-cluster-keys.md)). Files matching `clusters/home/.*\.sops\.yaml` have their `data` and `stringData` encrypted to the recipient in that repository's `.sops.yaml`, and the `cluster-secrets` Kustomization decrypts them at apply time with the `sops-age` secret. Secrets are grouped under `bootstrap/`, `platform/`, `identity/`, and `apps/`, each with its own kustomization listing its files explicitly. The Hetzner token in `bootstrap/hcloud.sops.yaml` is shared with the vigil project, so rotation must be coordinated across both. Edit a secret in place with `sops <path>`; add a new one by encrypting it and listing it in the folder kustomization.

Exactly one SOPS file remains in this repository, `kubernetes/clusters/home/bootstrap-secrets/bedrock-secrets-git-auth.sops.yaml`, which carries the read-only deploy key for the private repository and is decrypted by the same cluster age key. That key is therefore the only irreducible root: it opens the bootstrap secret, which opens the secrets repository, which holds everything else.

Two secrets are deliberately outside both repositories. The Rancher `cattle-system/bootstrap-secret` is generated by the chart on first install. The n8n encryption key was also chart-generated until it was moved into `bedrock-secrets` as `n8n-encryption-key`, because a chart-minted key is regenerated on a cold start and would leave every restored n8n credential undecryptable.

## Rehearsing recovery without an outage

These checks validate the chain on a schedule, without destructively touching the live cluster.

The evidence table below records what has actually been exercised. An earlier revision of this document stated that all of these had been run and passed. That was not true: no restore has ever been performed for any mechanism, and there has never been a Velero `Restore` object in this cluster. Entries move from untested to a date only when a drill has genuinely run.

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

- Age key decrypts. `sops -d` of a committed secret succeeds with the operator key. Proves the master seed.
- Host configurations build. `nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath` for each host, or `nixos-rebuild build`. Proves the OS layer is coherent.
- Re-key works. Decrypt a host secret with the operator identity, re-encrypt it to a freshly generated key, and decrypt with the new key. Proves the new-hardware re-key path.
- Backups restore. Restore a namespace into a temporary one and confirm the workload and any volume return:

  ```
  velero restore create drtest --from-backup <latest> \
    --include-namespaces <ns> --namespace-mappings <ns>:<ns>-drtest \
    --include-cluster-resources=false
  ```

  Confirm the pods run and any restored PersistentVolumeClaim binds with a healthy volume, then delete the temporary namespace. Three constraints make this narrower than it looks. The `velero` CLI is not installed on the operator workstation, so the drill either installs it or applies a `Restore` object directly. `--include-cluster-resources=false` is not optional: a daily backup holds around 2800 objects including cluster-scoped ones, and restoring those would overwrite live CRDs, ClusterRoles and webhook configurations. And the target namespace must not be one whose workloads depend on a Kyverno `PolicyException`, because exceptions match on the original namespace name and do not follow a remap, so the restored pods are rejected at admission. `n8n` is the correct drill target; `authentik`, `llm`, `minio`, `ntfy`, `paperless` and `postgres` are not.
- Fresh-cluster GitOps bootstrap. On a throwaway cluster such as `kind`, install Flux, create the `sops-age` secret from the operator key, point a GitRepository at this repository, and reconcile a SOPS-decrypting Kustomization. The secrets materialize as live Kubernetes Secrets, which proves the bootstrap and decryption path end to end. The full app set does not reconcile on unlike hardware, because the manifests assume the home storage, load balancer, addressing, and overlay; reconciling the whole stack elsewhere needs a cluster-appropriate overlay, the same overlay a standing cloud peer would use.

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
- kiwix is deliberately not backed up. Its 32 GB of ZIM files are re-downloaded from `download.kiwix.org` by an idempotent init container, so recovery is a redownload rather than a restore. Its backups previously failed at 85 percent anyway.
- Fifteen orphaned Longhorn `BackupVolume` objects remain for PVCs that no longer exist and will never be pruned. One of them holds the only surviving backup of the ollama volume.
- master's pinned filesystem UUIDs must be regenerated after a disk wipe.
- A full bare-metal rehearsal, re-imaging spare hardware end to end, and a full reconcile on unlike hardware both depend on a cluster-appropriate overlay that does not exist yet.

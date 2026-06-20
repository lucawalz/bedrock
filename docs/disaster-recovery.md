# Disaster recovery

How to rebuild the cluster from nothing, what has to survive outside it, and how to rehearse the recovery without causing an outage.

GitOps reconciles everything declared in this repository, so recovery is mostly a matter of reapplying it. What the repository cannot hold is a small set of seeds: the key that decrypts the secrets, the keys that identify the hosts, and the backup data itself. Recovery succeeds or fails on whether those seeds survive.

## Recovery seeds

These cannot live in the repository and must be kept somewhere that survives the loss of the cluster.

| Seed | What it is | Why it is not in Git |
| --- | --- | --- |
| Cluster age private key | The private half of the SOPS recipient, held in the cluster as the `sops-age` secret in `flux-system`. | It decrypts every committed secret. Only the public recipient is in `.sops.yaml`. |
| Host SSH private keys | `/etc/ssh/ssh_host_ed25519_key` on each node. | agenix encrypts host secrets to these. A fresh node generates new keys and cannot decrypt until they are restored or the secrets are re-keyed. |
| Velero backup data | The Hetzner object-storage bucket `horizon-velero-backups` and its S3 credentials. | The only copy of cluster data. The bucket persists outside the cluster. |
| The repository | This repository, or a fork. | Flux syncs from it and the rebuild reads it. |
| Operator identity | The admin SSH key, a recipient on every agenix secret. | Needed to re-key host secrets when host keys are lost. |

External account tokens for Hetzner, Cloudflare, Tailscale, and the Cluster API AWS IAM are stored as SOPS secrets, so they return once the age key is present, but the accounts and their issuers live outside the repository.

The age private key is held only on the operator's workstation, by choice. That is an accepted single point of failure: if both the workstation and the cluster are lost, the encrypted secrets are unrecoverable and must be reissued from their sources.

## Reconciliation order

Flux applies the cluster in dependency order, and a layer whose dependencies are not ready waits rather than failing:

1. `cluster-sources` and `cluster-namespaces` have no dependencies. Sources defines the HelmRepositories every release pulls from; namespaces are created before anything lands in them.
2. `cluster-secrets` decrypts the SOPS secrets, after the namespaces exist.
3. `cluster-infrastructure` applies networking, storage, databases, and monitoring, after sources, secrets, and namespaces.
4. `cluster-issuers` applies the cert-manager ClusterIssuers, after infrastructure.
5. `cluster-apps` applies the workloads, after infrastructure and issuers.

## Full rebuild from total loss

The order matters: network, then hosts, then K3s, then Flux, then the age key, then data.

1. Recover the seeds above: the age key, the Hetzner bucket and its credentials, the repository, the host keys if they were backed up, and a bootable NixOS installer.
2. Router first. Flash the Pi from the `router-installer` SD image. It brings up the VLANs, DHCP, DNS, and the gateway that the rest of the network needs.
3. Hosts. Get a minimal NixOS with SSH onto each node, then push its configuration:

   ```
   nixos-rebuild switch --flake .#master --target-host root@<ip>
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
8. Data. Velero reads the surviving bucket and restores the latest backup:

   ```
   velero restore create --from-backup <latest-daily-dr>
   ```

   The recovery point is the backup interval. The `daily-dr` schedule runs at 02:00, so up to a day of data is at risk.
9. Verify DNS and the Cloudflare tunnel, certificate issuance, ingress, and the app set.

## Secret recovery

Two mechanisms, recovered differently.

Host secrets use agenix. Each `.age` file under `secrets/` is encrypted to the SSH host keys of the machines that need it, plus the operator key, and a node decrypts its own secrets at boot. `secrets/secrets.nix` lists which recipients can open each secret. If a host key is lost with the hardware, re-key:

1. Collect the new host key with `ssh-keyscan -t ed25519 <host>`, or read `/etc/ssh/ssh_host_ed25519_key.pub`.
2. Update the recipient in `secrets/secrets.nix`.
3. Re-encrypt with a currently valid identity: `agenix -r` re-keys everything, or `agenix -e secrets/<name>.age` re-keys one.
4. Commit and rebuild the host.

Burst nodes do not use agenix; their join token and server address arrive through provisioning metadata.

Cluster secrets use SOPS with age. Files matching `kubernetes/.*/secrets/.*\.sops\.yaml` have their `data` and `stringData` encrypted to the recipient in `.sops.yaml`, and the `cluster-secrets` Kustomization decrypts them at apply time with the `sops-age` secret. The encrypted files are safe in a public repository; only the cluster holds the private key. Secrets are grouped under `bootstrap/`, `platform/`, `identity/`, and `apps/`, each with its own kustomization. The Hetzner token in `bootstrap/hcloud.sops.yaml` is shared with the vigil project, so rotation must be coordinated across both. Edit a secret in place with `sops <path>`; add a new one by encrypting it and listing it in the folder kustomization. The Rancher `cattle-system/bootstrap-secret` is generated by the chart on first install and intentionally stays out of Git.

## Rehearsing recovery without an outage

These checks validate the chain on a schedule, without destructively touching the live cluster. All have been run and passed.

- Age key decrypts. `sops -d` of a committed secret succeeds with the operator key. Proves the master seed.
- Host configurations build. `nix eval .#nixosConfigurations.<host>.config.system.build.toplevel.drvPath` for each host, or `nixos-rebuild build`. Proves the OS layer is coherent.
- Re-key works. Decrypt a host secret with the operator identity, re-encrypt it to a freshly generated key, and decrypt with the new key. Proves the new-hardware re-key path.
- Backups restore. Restore a namespace into a temporary one and confirm the workload and any volume return:

  ```
  velero restore create drtest --from-backup <latest> --namespace-mappings <ns>:<ns>-drtest
  ```

  Confirm the pods run and any restored PersistentVolumeClaim binds with a healthy volume, then delete the temporary namespace. This also confirms that backups flagged `PartiallyFailed` are still fully restorable, because the flag comes from a cosmetic plugin warning rather than missing data.
- Fresh-cluster GitOps bootstrap. On a throwaway cluster such as `kind`, install Flux, create the `sops-age` secret from the operator key, point a GitRepository at this repository, and reconcile a SOPS-decrypting Kustomization. The secrets materialize as live Kubernetes Secrets, which proves the bootstrap and decryption path end to end. The full app set does not reconcile on unlike hardware, because the manifests assume the home storage, load balancer, addressing, and overlay; reconciling the whole stack elsewhere needs a cluster-appropriate overlay, the same overlay a standing cloud peer would use.

## Known gaps

- The age key is held only on the operator's workstation, by choice.
- master's pinned filesystem UUIDs must be regenerated after a disk wipe.
- A full bare-metal rehearsal, re-imaging spare hardware end to end, and a full reconcile on unlike hardware both depend on a cluster-appropriate overlay that does not exist yet.

---
status: accepted
date: 2026-11-07
---

# 0005. Keep host secrets in agenix and cluster secrets in SOPS

## Context

Hosts and the cluster consume secrets at different times. A host needs its join token, tailnet auth key and backup credentials before K3s exists. The cluster needs Kubernetes Secrets that Flux can apply. This repository is public, so even ciphertext of cluster secrets is better kept out of it.

## Decision

- Host secrets are agenix files in `secrets/`, encrypted to the SSH host key of each machine that needs them and to two admin recipients, the `age-plugin-se` identity in the Secure Enclave of the admin Mac and the break-glass key on the offline medium, as listed in `secrets/secrets.nix`. They are decrypted at activation into `/run/agenix`.
- Cluster secrets are SOPS files encrypted to three age recipients and kept in the private `bedrock-secrets` repository. Flux pulls it as its own GitRepository, and the `cluster-secrets` Kustomization decrypts it with the `sops-age` Secret that `just bootstrap` creates.
- `just new-secret <app>` creates an app's SOPS files in `bedrock-secrets` from the same layout the scaffold expects ([0013](0013-keep-each-app-self-contained-and-scaffold-new-ones.md)).
- Machine secrets such as client secrets, cookie secrets and database passwords are generated straight into SOPS files and never printed.
- The recipients are an `age-plugin-se` identity in the Secure Enclave of the admin Mac, a new cluster key held only on the encrypted offline medium described in [0004](0004-keep-a-stable-cluster-ca-under-an-offline-root.md), and the current cluster key. The current key stays a recipient because the running cluster's `sops-age` Secret still holds it; it is dropped once the rebuilt cluster decrypts with the new key.

## Consequences

- A leak of this repository exposes no cluster secret, not even as ciphertext.
- A rebuild needs both repositories and the age key; without the key, every cluster Secret has to be recreated by hand.
- Two secret systems have to be learned, each matched to the stage at which its consumer runs.

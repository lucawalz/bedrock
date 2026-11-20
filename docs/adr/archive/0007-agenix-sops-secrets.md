# 7. Split secrets between agenix for hosts and SOPS for the cluster

Date: 2025-10-25

## Status

Accepted, cluster-secret custody superseded by [60. Private secrets repository with per-cluster keys](0060-private-secrets-repo-per-cluster-keys.md)

## Context

The repository is public, so every secret in it has to be committed encrypted and decrypted only where it is used. There are two distinct layers with different needs. NixOS hosts need a secret available at build or boot time, decrypted to a path on disk. The cluster needs secrets that Flux can decrypt in-cluster at reconcile time. One tool rarely serves both well.

### Options considered

- agenix plus SOPS, chosen. agenix decrypts to host paths during a NixOS build, which is exactly what a join token needs; SOPS integrates with Flux to decrypt manifests at reconcile time.
- sealed-secrets. Works for cluster secrets, but has no story for NixOS host secrets, so it would still need a second tool for the machine layer.
- Vault. Powerful and centralized, but it is a service to run, secure, and keep available, which is operational weight a single-operator homelab does not need.

## Decision

Host secrets use agenix, encrypted to each node's SSH host key and declared in `secrets/secrets.nix`. Cluster secrets use SOPS with age, configured in `.sops.yaml` and decrypted by Flux inside the cluster. Each tool is used where it fits: agenix for the machines, SOPS for the workloads.

## Consequences

Nothing sensitive sits in the repository in plaintext. The cost is two mechanisms rather than one, so contributors learn both. Key custody is the thing that actually has to be protected: whoever holds an age private key can decrypt the matching secrets, and the arrangement for the cluster keys is recorded in [0060](0060-private-secrets-repo-per-cluster-keys.md).

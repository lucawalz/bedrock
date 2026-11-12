---
status: accepted
date: 2026-11-07
---

# 0004. Keep a stable cluster CA under an offline root

## Context

K3s generates a fresh CA when its datastore is created. The K3s token in agenix, which the server and both agents share, is a secure token that pins the CA, so after the datastore was wiped for the rebuild the new server presented a CA the token did not match and both agents refused to join. Re-pinning the token on every rebuild, or falling back to a short token that pins nothing, would each give up something: a git-only rebuild in the first case, join authentication in the second.

## Decision

- The cluster CA is created once by `scripts/generate-cluster-ca.sh` and stays the same across rebuilds. A root CA signs intermediate CAs for the server, client, request-header and etcd roles, and the token pins the root.
- The root key never reaches a host. The root lives only offline, on the encrypted `bedrock-keys` medium, with no copy on the admin Mac. The SOPS age key and the Longhorn volume encryption key are kept on the same medium; with the root they are the three keys a rebuild from git cannot recreate. `scripts/generate-cluster-ca.sh` reads the root from the medium and refuses to run when it is not mounted.
- The intermediates, their keys and the service account key are age-encrypted to control-plane-1 and the admin as `secrets/k3s-ca.age`. The `k3s-ca` unit unpacks them into the K3s TLS directory before the first K3s start, and only when no `server-ca.crt` exists, so it can never replace the CA of a running cluster.

## Consequences

- A wiped server comes back with the same CA, and the existing token keeps working without a change in git.
- Rotating an intermediate needs the root key from offline storage. Losing the root key means minting a new CA and re-pinning the token, which is the cost this decision avoids.
- K3s does not restart when the token file changes in place, so a token rotation on a running cluster needs a manual restart of the agents.
- The etcd snapshots in R2 are not encrypted client-side, an accepted risk. K3s encrypts every Secret before it reaches etcd, and the bootstrap data in a snapshot, which holds the CA keys and the encryption key, is encrypted under the server token, so a leaked snapshot yields neither without that token. Until the agents get their own join token, both workers also hold the server token. Everything that is not a Secret, such as ConfigMaps and custom resources, is readable in a leaked snapshot.

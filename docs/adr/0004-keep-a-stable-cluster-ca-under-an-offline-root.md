---
status: accepted
date: 2026-11-07
---

# 0004. Keep a stable cluster CA under an offline root

## Context

K3s generates a fresh CA when its datastore is created. The agent join token in agenix is a secure token that pins the CA, so after the datastore was wiped for the rebuild the new server presented a CA the token did not match and both agents refused to join. Re-pinning the token on every rebuild, or falling back to a short token that pins nothing, would each give up something: a git-only rebuild in the first case, join authentication in the second.

## Decision

- The cluster CA is created once by `scripts/generate-cluster-ca.sh` and stays the same across rebuilds. A root CA signs intermediate CAs for the server, client, request-header and etcd roles, and the token pins the root.
- The root key never reaches a host. It lives on the admin Mac and on an encrypted offline medium, together with the SOPS age key and the Longhorn volume encryption key, which are the three keys a rebuild from git cannot recreate.
- The intermediates, their keys and the service account key are age-encrypted to control-plane-1 and the admin as `secrets/k3s-ca.age`. The `k3s-ca` unit unpacks them into the K3s TLS directory before the first K3s start, and only when no `server-ca.crt` exists, so it can never replace the CA of a running cluster.

## Consequences

- A wiped server comes back with the same CA, and the existing agent token keeps working without a change in git.
- Rotating an intermediate needs the root key from offline storage. Losing the root key means minting a new CA and re-pinning the token, which is the cost this decision avoids.
- K3s does not restart when the token file changes in place, so a token rotation on a running cluster needs a manual restart of the agents.

---
status: accepted
date: 2026-07-06
---

# 0060. Private secrets repository with per-cluster keys

## Context

The bedrock repository is public by design. It is a showcase, an estate whose manifests and architecture are meant to be read, and that openness is the point. [0007](0007-agenix-sops-secrets.md) split the estate's secrets by layer, host secrets under agenix encrypted to each node's SSH host key and cluster secrets under SOPS with age decrypted by Flux at reconcile time, and recorded that the age private key is the thing that actually has to be protected. Both halves of that split lived in the public repository. The cluster secrets were SOPS-encrypted, so nothing sensitive sat in plaintext, but the ciphertext of live credentials was committed into a public archive and stayed there permanently in the git history. Encryption was the only barrier, with no repository-access layer behind it, so the exposure was a harvest-now-decrypt-later one: an attacker can copy the ciphertext today and hold it against the day the key or the cipher weakens. A full-history scan found no committed private key and no plaintext secret, so this was a posture weakness rather than a breach, but a posture resting on key secrecy alone has no defence in depth. Two further constraints shape the fix. Cross-region peers must be able to decrypt their own secrets without ever holding home's key, so a single universal decryptor is not acceptable, and the agenix and SOPS split stays as it is.

## Decision

Keep bedrock public and move the encrypted cluster secrets out of it into a separate private repository. Home Flux now reconciles two sources: the public repository continues to carry the manifests and architecture, and a new GitRepository points at the private one, authenticated with a read-only deploy key. That deploy key is itself a SOPS secret committed to the public repository and delivered by a small bootstrap Kustomization, decrypted by the existing home age key, so reaching the private repository introduces no new out-of-band root and the only irreducible root remains home's age key, exactly as [0007](0007-agenix-sops-secrets.md) already required. Secrets are organised per cluster, and the SOPS creation rules key an age recipient to each cluster path, so a given cluster is encrypted only to its own recipient. A cluster can therefore decrypt only its own secrets, home's key is never listed on a peer's path, and there is no key that reads everything. The migration moved the existing ciphertext verbatim with no re-encryption and repointed only the single `cluster-secrets` Kustomization, which is safe because secrets are consumed in the cluster by name rather than by repository path. The private repository mirrors the public repository's hygiene, adds a continuous-integration gate that fails on any secret that is not encrypted, and never holds a decryption key of its own.

## Options considered

- Accept the public ciphertext and rely on key secrecy alone. The status quo before this decision, rejected because permanent archival of live-credential ciphertext in a public history removes any defence in depth. The moment the key is exposed or the cipher ages, every secret ever committed is readable, and the archive cannot be recalled.
- Make the whole bedrock repository private. This closes the exposure but discards the reason bedrock exists. The estate is a showcase meant to be read, and sealing it to protect a handful of encrypted files trades the entire purpose of the repository for a gain that a narrower split delivers just as well.
- Split only the secrets into a private repository, chosen. It removes the live-credential ciphertext from the public archive while the manifests and architecture stay public. The cost is a second source for Flux to reconcile, which the deploy-key bootstrap keeps rooted in the existing home key.
- For the peer decryption model, per-cluster SOPS and age was chosen over Sealed Secrets and an external secrets operator. Per-cluster age recipients give each cluster a key that reads only its own secrets while adding no new infrastructure and keeping one toolchain, where the alternatives each introduce a running component to install, secure, and keep available.

## Consequences

Live-credential ciphertext leaves the public archive while the showcase stays public, so the harvest-now-decrypt-later exposure is closed without giving up the reason bedrock is open. The estate becomes a single GitOps system spread across two sources, and an operator now reasons about both when tracing how a secret reaches a workload. The private repository and its read-only deploy key join home's age key as recovery-critical roots that must be backed up offline, since losing either breaks the estate's ability to reconcile its secrets. Per-cluster keys give peer secret isolation with home's key never leaving home, so a compromised peer exposes only its own secrets and never becomes a path to the rest of the estate.

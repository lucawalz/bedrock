---
status: accepted
date: 2026-07-06
---

# 0060. Private secrets repository with per-cluster keys

## Context

The bedrock repository is public by design. It is a showcase, an estate whose manifests and architecture are meant to be read, and that openness is the point rather than an accident. ADR 0007 split the estate's secrets by layer, host secrets under agenix encrypted to each node's SSH host key and cluster secrets under SOPS with age decrypted by Flux at reconcile time, and it recorded that the age private key is the thing that actually has to be protected because whoever holds it can decrypt the cluster secrets.

Both halves of that split lived in the public repository. The cluster secrets were SOPS-encrypted, so nothing sensitive sat in plaintext, but the ciphertext of live credentials was committed into a public archive and stayed there permanently in the git history. Encryption was the only barrier, with no repository-access layer behind it, so the exposure was a harvest-now-decrypt-later one: an attacker can copy the ciphertext today and hold it against the day the age key or the cipher weakens. A full-history scan with gitleaks and trufflehog found no committed private key and no plaintext secret, so this was a posture weakness rather than a breach, but a posture that rests on key secrecy alone has no defence in depth.

Two further constraints shape the fix. Cross-region peers must be able to decrypt their own secrets without ever holding home's key, so a single universal decryptor is not acceptable. And the agenix and SOPS split from ADR 0007 stays as it is; this decision concerns only where the SOPS cluster secrets are stored and which key can read them.

## Decision

Keep bedrock public and move the encrypted cluster secrets out of it into a separate private repository, bedrock-secrets. Home Flux now reconciles two sources. The public repository continues to carry the manifests and architecture, and a new GitRepository named `bedrock-secrets` points at `ssh://git@github.com/lucawalz/bedrock-secrets`, authenticated with a read-only deploy key held in the `bedrock-secrets-git-auth` secret.

That deploy key is itself a SOPS secret committed to the public repository, at `clusters/home/bootstrap-secrets/bedrock-secrets-git-auth.sops.yaml`, and delivered by a small bootstrap Kustomization. It is decrypted by the existing home sops-age key, so reaching the private repository introduces no new out-of-band root: the only irreducible root remains home's age key, exactly as ADR 0007 already required. The `cluster-secrets` Kustomization now takes its `sourceRef` from the `bedrock-secrets` GitRepository at path `clusters/home` and decrypts with the same `sops-age` secret.

Secrets are organised per cluster under `clusters/<cluster>/`, and the SOPS creation rules in `.sops.yaml` key an age recipient to each cluster path, so a given cluster is encrypted only to its own recipient. A cluster can therefore decrypt only its own secrets, home's key is never listed on a peer's path, and there is no key that reads everything. The migration moved the existing ciphertext verbatim with no re-encryption and repointed only the single `cluster-secrets` Kustomization, which is safe because secrets are consumed in the cluster by name rather than by repository path, so the source of the ciphertext can change without touching any consumer. The private repository mirrors the public repository's hygiene and adds a continuous-integration gate that fails on any secret that is not encrypted and never holds a decryption key of its own.

## Options considered

- Accept the public ciphertext and rely on key secrecy alone. This is the status quo before this decision. It is rejected because permanent archival of live-credential ciphertext in a public history removes any defence in depth: the moment the age key is exposed or the cipher ages, every secret ever committed is readable, and the archive cannot be recalled.
- Make the whole bedrock repository private. This closes the exposure but discards the reason bedrock exists. The estate is a showcase meant to be read, and sealing it to protect a handful of encrypted files trades the entire purpose of the repository for a gain that a narrower split delivers just as well.
- Split only the secrets into a private repository, chosen. It removes the live-credential ciphertext from the public archive while the manifests and architecture stay public, so the exposure closes without splitting the logic of the estate. The cost is a second source for Flux to reconcile, which the deploy-key bootstrap keeps rooted in the existing home key.
- For the peer decryption model, per-cluster SOPS and age was chosen over Sealed Secrets and an external secrets operator. Per-cluster age recipients give each cluster a key that reads only its own secrets while adding no new infrastructure and keeping one toolchain. Sealed Secrets and an external secrets operator both introduce a running component to install, secure, and keep available, which is operational weight this estate does not need to gain peer isolation that age recipients already provide.

## Consequences

Live-credential ciphertext leaves the public archive while the showcase stays public, so the harvest-now-decrypt-later exposure is closed without giving up the reason bedrock is open. The estate becomes a single GitOps system spread across two sources, one public for manifests and one private for secrets, and an operator now reasons about both when tracing how a secret reaches a workload. The private repository and its read-only deploy key join home's age key as recovery-critical roots that must be backed up offline, since losing the private repository or the key custody around it breaks the estate's ability to reconcile its secrets. Per-cluster keys give peer secret isolation with home's key never leaving home, so a compromised peer exposes only its own secrets and never becomes a path to the rest of the estate.

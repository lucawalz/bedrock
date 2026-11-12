---
status: accepted
date: 2026-11-07
---

# 0014. Pin versions and update them with Renovate

## Context

A rebuild from git only reproduces the cluster if git names exact versions. Floating tags and version ranges make two applies of the same commit install different software. Pinning everything by hand, on the other hand, leaves the cluster to age.

## Decision

- Every chart, image, Flux distribution line, Nix input and GitHub Action is pinned. Images use explicit tags, Actions use commit SHAs with the version as a comment, and the Nix inputs are fixed by `flake.lock`. Kyverno rejects the `latest` tag at admission ([0009](0009-enforce-workload-policy-with-kyverno.md)).
- Renovate moves the pins. A release must be three days old before it is proposed. Minor, patch and digest updates merge automatically.
- Some updates are held for review, with automerge off, and wait as open pull requests: every major, and minors and patches of the components whose upgrade can break the cluster or loses data, listed below by the dependency name Renovate extracts. Every app that holds personal data is on the list. `scripts/check-renovate-managers.sh` fails CI when a listed name no longer appears in the repository or no hold rule matches it.
- Stateful components step one minor at a time. A CRD chart ships in the same pull request as the chart whose controller reads it.
- Versions that no built-in manager can see are tracked by custom managers, and `scripts/check-renovate-managers.sh` fails CI when a custom manager no longer matches any file.
- Renovate also moves the blog image. It orders the `main-<timestamp>-<sha>` tags by timestamp, skips the release age wait and merges every build without review. Nothing in the cluster writes to git: the image reflector and automation controllers are not installed, and the Flux deploy key is read-only.

### Held for review

| Component | Dependency names |
| --- | --- |
| Longhorn | `longhorn` |
| CloudNativePG | `cloudnative-pg`, `plugin-barman-cloud` |
| kube-prometheus-stack | `kube-prometheus-stack`, `prometheus-operator-crds` |
| cert-manager | `cert-manager` |
| Traefik | `traefik`, `traefik-crds` |
| MetalLB | `metallb` |
| Kyverno | `kyverno` |
| Flux | `flux-operator`, `fluxcd/flux2` |
| Pocket ID | `ghcr.io/pocket-id/pocket-id` |
| oauth2-proxy | `oauth2-proxy` |
| Loki, Tempo and Alloy | `loki`, `tempo`, `alloy` |
| Flagger | `flagger` |
| Job runtime | `python` |
| Paperless | `paperless-ngx`, `ghcr.io/paperless-ngx/paperless-ngx`, `docker.io/icereed/paperless-gpt` |
| LiteLLM | `ghcr.io/berriai/litellm` |
| Open WebUI | `open-webui` |
| ntfy | `docker.io/binwiederhier/ntfy` |
| cloudflared | `cloudflare/cloudflared` |
| zot | `zot`, `ghcr.io/project-zot/zot` |

## Consequences

- The same commit installs the same versions on every rebuild.
- Low-risk updates arrive without attention; the risky ones wait as open pull requests and need a deliberate merge.
- A blog build reaches the cluster on the next Renovate run rather than within minutes.

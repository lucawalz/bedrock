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
- Some updates are held for review: every major, minors and patches of the components whose upgrade can break the cluster or its data (Longhorn, CloudNativePG and its backup plugin, kube-prometheus-stack, cert-manager, Traefik, MetalLB, Kyverno, the Flux Operator, Flux itself, Pocket ID, oauth2-proxy, Loki, Tempo, Alloy, Paperless and Flagger).
- Stateful components step one minor at a time. A CRD chart ships in the same pull request as the chart whose controller reads it.
- Versions that no built-in manager can see are tracked by custom managers, and `scripts/check-renovate-managers.sh` fails CI when a custom manager no longer matches any file.
- The blog image is the one exception: Flux image automation owns its tag, and Renovate ignores it.

## Consequences

- The same commit installs the same versions on every rebuild.
- Low-risk updates arrive without attention; the risky ones wait in the dependency dashboard and need a deliberate merge.
- Image automation pushes to `main`, so the Flux deploy key needs write access.

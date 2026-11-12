---
status: accepted
date: 2026-11-07
---

# 0014. Pin versions and update them with Renovate

## Context

A rebuild from git only reproduces the cluster if git names exact versions. Floating tags and version ranges make two applies of the same commit install different software. Pinning everything by hand, on the other hand, leaves the cluster to age.

## Decision

- Every chart, image, Flux distribution line, Nix input and GitHub Action is pinned. Images carry a tag and its digest (`tag@sha256:...`), Actions use commit SHAs with the version as a comment, and the Nix inputs are fixed by `flake.lock`. Kyverno rejects the `latest` tag at admission ([0009](0009-enforce-workload-policy-with-kyverno.md)).
- A chart's default images are set explicitly in its HelmRelease values, so Renovate sees them and pins their digests. Renovate ships a chart and the images in its HelmRelease in one pull request. `scripts/check-manifests.sh` renders every workload and fails when a container image, or a Prometheus Operator image, lacks a digest, and when a Prometheus or Alertmanager `version` no longer matches its image tag.
- Digest-exempt:
  - The Flux controllers. The Flux Operator installs them from the `FluxInstance` already pinned by digest, and no values set them.
  - The images below, listed in `digest_exempt_images`.
  - Longhorn engine and instance manager. Longhorn names an EngineImage or instance manager after its image string, so a new string starts an engine upgrade that stays manual here.
  - Longhorn share manager and backing image manager. Each ShareManager and BackingImageManager records its image, so a new string replaces the NFS server of a shared volume or the manager that serves backing images on a disk.
  - Longhorn support bundle kit. It runs only for a requested support bundle and holds no data; it stays on the same tag-only setting as the other images Longhorn launches, whose digest support is unverified.
  - The CloudNativePG PostgreSQL image. It is the operator default, and setting `imageName` in the `Cluster` rolls every database instance.
- Chart hooks are rendered and checked too. Their images are pinned in values, and a test hook that nothing runs is switched off where the chart allows it.
- CI downloads its tools only after `sha256sum -c` against a checksum pinned next to the version, so a tool bump needs its new checksum in the same change. `bedrock-secrets` and `blog` pin their Actions by commit SHA as well.
- Renovate moves the pins. A release must be three days old before it is proposed, except an image release that carries no release timestamp, as most images here do not; such an image would otherwise never update and leave its chart running old images. Minor, patch and digest updates merge automatically.
- Some updates are held for review, with automerge off, and wait as open pull requests: every major, and minors and patches of the components whose upgrade can break the cluster or lose data, listed below by the dependency name Renovate extracts. Every app that holds personal data is on the list. `scripts/check-renovate-managers.sh` fails CI when a listed name no longer appears in the repository or no hold rule matches it.
- Stateful components step one minor at a time. A CRD chart ships in the same pull request as the chart whose controller reads it.
- Versions that no built-in manager can see are tracked by custom managers, and `scripts/check-renovate-managers.sh` fails CI when a custom manager no longer matches any file.
- Renovate also moves the blog image. It orders the `main-<timestamp>-<sha>` tags by timestamp, skips the release age wait and merges every build without review. Nothing in the cluster writes to git: the image reflector and automation controllers are not installed, and the Flux deploy key is read-only.

### Held for review

| Component | Dependency names |
| --- | --- |
| Longhorn | `longhorn`, `docker.io/longhornio/longhorn-manager`, `docker.io/longhornio/longhorn-ui`, `docker.io/longhornio/csi-attacher`, `docker.io/longhornio/csi-provisioner`, `docker.io/longhornio/csi-node-driver-registrar`, `docker.io/longhornio/csi-resizer`, `docker.io/longhornio/csi-snapshotter`, `docker.io/longhornio/livenessprobe` |
| CloudNativePG | `cloudnative-pg`, `plugin-barman-cloud`, `ghcr.io/cloudnative-pg/cloudnative-pg`, `ghcr.io/cloudnative-pg/plugin-barman-cloud`, `ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar` |
| kube-prometheus-stack | `kube-prometheus-stack`, `prometheus-operator-crds`, `quay.io/prometheus-operator/prometheus-operator`, `quay.io/prometheus-operator/prometheus-config-reloader`, `quay.io/prometheus/prometheus`, `quay.io/prometheus/alertmanager`, `quay.io/prometheus/node-exporter`, `registry.k8s.io/kube-state-metrics/kube-state-metrics`, `quay.io/kiwigrid/k8s-sidecar`, `ghcr.io/jkroepke/kube-webhook-certgen` |
| cert-manager | `cert-manager`, `quay.io/jetstack/cert-manager-controller`, `quay.io/jetstack/cert-manager-webhook`, `quay.io/jetstack/cert-manager-cainjector`, `quay.io/jetstack/cert-manager-acmesolver`, `quay.io/jetstack/cert-manager-startupapicheck` |
| Traefik | `traefik`, `traefik-crds`, `docker.io/traefik` |
| MetalLB | `metallb`, `quay.io/metallb/controller`, `quay.io/metallb/speaker`, `quay.io/metallb/frr-k8s`, `quay.io/frrouting/frr` |
| Kyverno | `kyverno`, `reg.kyverno.io/kyverno/kyverno`, `reg.kyverno.io/kyverno/kyvernopre`, `reg.kyverno.io/kyverno/background-controller`, `reg.kyverno.io/kyverno/cleanup-controller`, `reg.kyverno.io/kyverno/reports-controller`, `reg.kyverno.io/kyverno/kyverno-cli`, `ghcr.io/kyverno/readiness-checker` |
| Flux | `flux-operator`, `ghcr.io/controlplaneio-fluxcd/flux-operator`, `fluxcd/flux2` |
| Pocket ID | `ghcr.io/pocket-id/pocket-id` |
| oauth2-proxy | `oauth2-proxy`, `quay.io/oauth2-proxy/oauth2-proxy` |
| Loki, Tempo and Alloy | `loki`, `tempo`, `alloy`, `docker.io/grafana/loki`, `docker.io/grafana/tempo`, `docker.io/grafana/alloy` |
| Flagger | `flagger`, `ghcr.io/fluxcd/flagger` |
| Job runtime | `python` |
| Paperless | `paperless-ngx`, `ghcr.io/paperless-ngx/paperless-ngx`, `docker.io/icereed/paperless-gpt` |
| LiteLLM | `ghcr.io/berriai/litellm` |
| Open WebUI | `open-webui`, `ghcr.io/open-webui/open-webui` |
| ntfy | `docker.io/binwiederhier/ntfy` |
| cloudflared | `cloudflare/cloudflared` |
| zot | `zot`, `ghcr.io/project-zot/zot` |

## Consequences

- The same commit installs the same versions on every rebuild.
- Low-risk updates arrive without attention; the risky ones wait as open pull requests and need a deliberate merge.
- A blog build reaches the cluster on the next Renovate run rather than within minutes.
- An image that a chart defaults no longer follows the chart by itself: its tag moves through Renovate in the chart's pull request.
- A digest change of an unchanged tag restarts the workload, so rebuilt upstream images arrive as digest updates.

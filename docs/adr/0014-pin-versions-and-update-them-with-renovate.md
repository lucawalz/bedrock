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
- Exempt from digests: the Flux controllers, which the Flux Operator installs from the `FluxInstance` and already pins by digest without values to set, and the Longhorn data-plane images (engine, instance manager, share manager, backing image manager, support bundle kit), because Longhorn treats each image string as the identity of an engine or instance manager and a changed string starts an engine upgrade. Only the share manager appears in a rendered pod; it is listed in `digest_exempt_images`. CloudNativePG's PostgreSQL image is the operator default and is not pinned in the `Cluster`, since setting it restarts the database.
- CI downloads its tools only after `sha256sum -c` against a checksum pinned next to the version, so a tool bump needs its new checksum in the same change. `bedrock-secrets` and `blog` pin their Actions by commit SHA as well.
- Renovate moves the pins. A release must be three days old before it is proposed. Minor, patch and digest updates merge automatically.
- Some updates are held for review, with automerge off, and wait as open pull requests: every major, and minors and patches of the components whose upgrade can break the cluster or lose data, listed below by the dependency name Renovate extracts. Every app that holds personal data is on the list. `scripts/check-renovate-managers.sh` fails CI when a listed name no longer appears in the repository or no hold rule matches it.
- Stateful components step one minor at a time. A CRD chart ships in the same pull request as the chart whose controller reads it.
- Versions that no built-in manager can see are tracked by custom managers, and `scripts/check-renovate-managers.sh` fails CI when a custom manager no longer matches any file.
- Renovate also moves the blog image. It orders the `main-<timestamp>-<sha>` tags by timestamp, skips the release age wait and merges every build without review. Nothing in the cluster writes to git: the image reflector and automation controllers are not installed, and the Flux deploy key is read-only.

### Held for review

| Component | Dependency names |
| --- | --- |
| Longhorn | `longhorn`, `docker.io/longhornio/longhorn-manager`, `docker.io/longhornio/longhorn-ui`, `docker.io/longhornio/csi-attacher`, `docker.io/longhornio/csi-provisioner`, `docker.io/longhornio/csi-node-driver-registrar`, `docker.io/longhornio/csi-resizer`, `docker.io/longhornio/csi-snapshotter`, `docker.io/longhornio/livenessprobe` |
| CloudNativePG | `cloudnative-pg`, `plugin-barman-cloud`, `ghcr.io/cloudnative-pg/cloudnative-pg`, `ghcr.io/cloudnative-pg/plugin-barman-cloud`, `ghcr.io/cloudnative-pg/plugin-barman-cloud-sidecar` |
| kube-prometheus-stack | `kube-prometheus-stack`, `prometheus-operator-crds`, `quay.io/prometheus-operator/prometheus-operator`, `quay.io/prometheus-operator/prometheus-config-reloader`, `quay.io/prometheus/prometheus`, `quay.io/prometheus/alertmanager`, `quay.io/prometheus/node-exporter`, `registry.k8s.io/kube-state-metrics/kube-state-metrics`, `quay.io/kiwigrid/k8s-sidecar` |
| cert-manager | `cert-manager`, `quay.io/jetstack/cert-manager-controller`, `quay.io/jetstack/cert-manager-webhook`, `quay.io/jetstack/cert-manager-cainjector`, `quay.io/jetstack/cert-manager-acmesolver`, `quay.io/jetstack/cert-manager-startupapicheck` |
| Traefik | `traefik`, `traefik-crds`, `docker.io/traefik` |
| MetalLB | `metallb`, `quay.io/metallb/controller`, `quay.io/metallb/speaker`, `quay.io/metallb/frr-k8s`, `quay.io/frrouting/frr` |
| Kyverno | `kyverno`, `reg.kyverno.io/kyverno/kyverno`, `reg.kyverno.io/kyverno/kyvernopre`, `reg.kyverno.io/kyverno/background-controller`, `reg.kyverno.io/kyverno/cleanup-controller`, `reg.kyverno.io/kyverno/reports-controller` |
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

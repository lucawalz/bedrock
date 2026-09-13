---
status: accepted
date: 2026-09-13
---

# 0087. Record the Flux Kustomization layering that replaced the four-way split

## Context

[0058](0058-split-cluster-infrastructure-kustomizations.md) split `cluster-infrastructure` into `cluster-storage`, `cluster-networking`, `cluster-monitoring` and `cluster-security`. The day after that split landed, `kubernetes/clusters/home/config/` was re-sorted into layer files and two of those four names disappeared. Nothing recorded what replaced them, so 0058 pointed at a set of names only half of which exist, and every audit of the estate has had to read the config directory to work out the current shape and then guess at the rule behind it.

## Decision

Record the layering as it stands, and treat this record as the successor to 0058's names rather than to its reasoning.

Four Kustomizations carry the foundation. `cluster-sources` and `cluster-namespaces` declare no dependency of their own and reconcile first. `cluster-bootstrap-secrets` follows the namespaces, and `cluster-secrets`, which reconciles the private secrets repository of [0060](0060-private-secrets-repo-per-cluster-keys.md), follows the other three. Every other Kustomization names the roots it consumes, which for several is none of the four, together with the Kustomization that installs the controller whose objects it needs.

Above the foundation, `base.yaml` holds the controllers the rest of the estate assumes: cert-manager and its issuers, storage, the CNPG operator, security, delivery, notifications, Alloy, CoreDNS and metrics-server. `edge-onprem.yaml` holds the on-premises ingress path and the MetalLB address pool that depends on it. `fleet.yaml` holds Rancher, observability and the Flux operator. `home.yaml` holds the concerns particular to this cluster: the databases, Authentik, pgAdmin, MinIO, the orphan reaper, horizon and the Flux instance. Three concerns keep a file each: `apps.yaml` for `cluster-apps`, which lays down the per-app Kustomizations of [0066](0066-standardize-app-delivery-per-app-kustomizations.md), `policies.yaml` for `cluster-policies`, and `zot.yaml` for `cluster-zot`.

The files are an editorial grouping and nothing more. Flux reads each Kustomization on its own, so `dependsOn` and only `dependsOn` decides what reconciles when. The rule a new Kustomization follows is therefore about dependencies, not about which file it lands in: depend on the sources, secrets and namespaces it consumes, and on the Kustomization that installs the controller whose custom resource definitions it needs. `cluster-policies` depends on `cluster-security` for exactly that reason. The admission window that opens because the application tier waits on neither of them is recorded in [0082](0082-gitops-guardrail-boundary.md) rather than restated here.

## Options considered

- Record the current layering and mark 0058's names superseded, chosen. The layering is what the cluster already does, and writing it down turns a repeated rediscovery into something that can be read once while leaving 0058's blast-radius reasoning intact.
- Rewrite 0058 in place to describe the current names. Rejected, because it would erase the four-way split and the adopt-then-reprune migration that justified it, which is the part of that record still worth reading.
- Leave the successor unrecorded and keep reading the config directory. Rejected, because the directory states which Kustomizations exist and never states the rule that decides a new one's dependencies, which is the part that was being guessed.

## Consequences

The layering has a record, 0058 points at it, and the rule for adding a Kustomization is written down instead of inferred from the neighbours.

Two costs follow. The membership lists above drift as concerns are added or retired, so this record needs amending when they do; the rule in the Decision does not drift and is the part worth keeping accurate. And the foundation is a single ordering bottleneck: `cluster-sources` not being ready holds almost every other Kustomization behind it, which shows up as a wall of dependency-not-ready messages during any source reconcile and is normal rather than a fault.

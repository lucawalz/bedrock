---
status: accepted
date: 2026-11-07
---

# 0013. Keep each app self-contained and scaffold new ones

## Context

Before the rebuild, onboarding an app with a database and single sign-on touched about sixteen files, nine or ten of them outside the app's folder, and half of those changes had no CI guard. Every new app repeated the same namespace, policy, ingress and alerting boilerplate by hand.

## Decision

- An app lives entirely in `kubernetes/apps/<name>/`: its `namespace.yaml` (with pruning disabled, Pod Security labels, the opt-in labels of [0008](0008-deny-network-traffic-by-default.md) and a default ServiceAccount that mounts no token), a `ks.yaml` with its Flux Kustomizations and a Flux Alert for its HelmReleases, an `app/` folder, and optionally `db/` ([0007](0007-share-one-cloudnativepg-cluster-with-per-app-databases.md)) and folders for its Jobs.
- Outside the folder an app adds one line to `kubernetes/apps/kustomization.yaml`, which `cluster-apps` applies, and a row in the generated `docs/inventory.md`. `scripts/check-apps-index.sh` fails CI when the index and the folders disagree. The app's secrets live in `bedrock-secrets` ([0005](0005-keep-host-secrets-in-agenix-and-cluster-secrets-in-sops.md)).
- Shared behaviour is pulled in as Kustomize components rather than copied: network policies, forward-auth, topology spread and the dependency wait.
- `just new-app <name> <host> <port> [db] [sso] [image]` writes the folder on the bjw-s app-template chart with the policies Kyverno enforces already met, adds the index line and runs every repository check. `just new-secret <app>` writes the matching secrets with random values.
- Routine operations are one recipe each: `just reconcile`, `logs`, `psql`, `dump`, `restore`, `login` and `backup`.

## Consequences

- Adding or removing an app is a change to one folder, the index, the inventory and the secrets repository.
- Namespaces are never pruned, so removing an app leaves its namespace for a deliberate delete rather than losing its volumes to a typo in the index.
- Every Kustomization's failure events come from the central Alert, and each app's own Alert covers only the HelmReleases in its namespace, so nothing is reported twice.

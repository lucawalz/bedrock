---
status: accepted
date: 2026-06-20
---

# 0046. Provision Postgres declaratively with CloudNativePG

## Context

The cluster ran a single Postgres server from the Bitnami chart, with the databases and login roles for its two consumers, authentik and litellm, created out of band by imperative jobs. Each consumer carried a `db-init` Job that shelled into `psql` as the superuser and guarded a `CREATE ROLE` and `CREATE DATABASE` behind existence checks, reading a throwaway init password from its own SOPS secret that had to be kept in lockstep with the connection string the app used. litellm's Job ran under its own Flux Kustomization so it could be forced ahead of the app, which meant a standing per-app Kustomization, an init secret, and a connection secret all encoding the same password in three places. Schema creation was procedural state layered on a chart that has no concept of the roles or databases it serves, and drift between the declared connection config and the actual role password was a recurring failure the system could not reconcile away. n8n had been wired into the same machinery but runs on SQLite, so its only remaining tie to Postgres was a stale network-policy egress allow.

## Decision

Adopt CloudNativePG as the Postgres operator, and declare the cluster, its login roles, and its databases as custom resources. The operator installs from its Helm chart into `cnpg-system` under its own Flux Kustomization that waits on the CRDs before anything consumes them. A single-instance `Cluster` named `postgres` holds the data on a Longhorn volume sized to match the old one, with `enableSuperuserAccess` so pgAdmin keeps its superuser entry point. The login roles are declared in `.spec.managed.roles`, each binding its password to a `kubernetes.io/basic-auth` secret labelled for operator reload, and the two application databases are declared as `Database` resources owned by those roles. The operator reconciles roles and databases into existence and corrects their state, so role-password drift is no longer possible: the password lives in one SOPS secret, the operator sets the role from it, and the app reads the same value.

The consumers move to the `postgres-rw` service, and ordering is expressed through split Kustomizations, with the database Kustomization depending on the operator one and the authentik and apps Kustomizations depending on the database one, so no app reconciles before its role and database exist. The cutover is a clean slate: the existing data is discarded by choice and both consumers recreate their schemas on first boot. This retires the Bitnami `postgresql` HelmRelease and its source, both `db-init` Jobs and their SOPS init secrets, and the standalone `litellm-db-init` Kustomization.

## Options considered

- Keep Bitnami and the imperative db-init Jobs, hardening them into a CronJob for drift correction. This keeps a working setup but leaves schema provisioning as procedural state outside the chart, keeps each password duplicated across two secrets, and never gains self-healing roles. It treats the symptom and leaves the missing abstraction in place.
- Crossplane with a `provider-sql`. This declares roles and databases as resources but bolts a second control plane and a generic SQL provider onto a server the cluster still has to run and back up separately, with no operator-level understanding of Postgres failover, backups, or instance lifecycle.
- CloudNativePG, chosen. It owns the server, the roles, and the databases as first-class declarative resources under one operator, reconciles them continuously, and folds password management into the role definition. It replaces the chart, both init Jobs, both init secrets, and the per-app Kustomization with a `Cluster`, two `Database` resources, and two basic-auth secrets.

## Consequences

Database provisioning is declarative and self-healing: a role or database that is deleted or drifts is reconciled back, and a password change in the SOPS secret propagates without a job run. The cost is a one-time data reset at cutover, accepted because both consumers rebuild their schemas on boot. CRD ordering is load-bearing and expressed through Flux Kustomization dependencies rather than a forced single apply, since the `Cluster`, `Database`, and managed-role resources cannot be validated before the operator's CRDs exist. The network policy that fronted the old chart pods by their Bitnami labels is rewritten to select the CNPG instance pods by `cnpg.io/cluster: postgres`, the consumers' egress allows follow the same relabel, and the stale n8n egress is removed.

Backups were deferred here to a later record, on the reasoning that Velero already snapshotted the Longhorn volume and a Barman object-store backup understanding point-in-time recovery could follow once the operator was bedded in. [0057](0057-cnpg-barman-dr-and-velero-scope.md) adopted that Barman backup, and [0081](0081-retire-the-hetzner-account.md) removed both it and Velero with the Hetzner account before repointing the same Barman shape at in-cluster MinIO. The declarative provisioning this record decided is unaffected by any of that.

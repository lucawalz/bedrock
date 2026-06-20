---
status: accepted
date: 2026-06-20
---

# 0046. Provision Postgres declaratively with CloudNativePG

## Context

The cluster ran a single Postgres server from the Bitnami chart, with the databases and login roles for the two consumers, authentik and litellm, created out of band by imperative jobs. Each consumer carried a `db-init` Job that shelled into `psql` as the superuser, guarded a `CREATE ROLE` and `CREATE DATABASE` behind existence checks, and read a throwaway init password from its own SOPS secret that had to be kept in lockstep with the connection string the app used. litellm's Job ran under its own Flux Kustomization so it could be forced ahead of the app, which meant a standing per-app Kustomization, an init secret, and a connection secret all encoding the same password in three places. The schema-creation step was procedural state layered on top of a chart that has no concept of the roles or databases it serves, so drift between the declared connection config and the actual role password was a recurring failure mode rather than something the system could reconcile away.

n8n was wired into the same machinery historically but runs on SQLite, so its only remaining tie to Postgres was a stale network-policy egress allow.

## Decision

Adopt CloudNativePG as the Postgres operator, and declare the cluster, its login roles, and its databases as custom resources.

The operator installs from its Helm chart into `cnpg-system` under its own Flux Kustomization that waits on the CRDs before anything consumes them. A single-instance `Cluster` named `postgres` holds the data on a Longhorn volume sized to match the old one, with `enableSuperuserAccess` so pgAdmin keeps its superuser entry point. The login roles for litellm and authentik are declared in `.spec.managed.roles`, each binding its password to a `kubernetes.io/basic-auth` secret labelled for operator reload, and the two application databases are declared as `Database` resources owned by those roles. The operator reconciles the roles and databases into existence and corrects their state, so role-password drift is no longer possible: the password lives in one SOPS secret, the operator sets the role from it, and the app reads the same value from its own connection config kept in sync at the source.

The consumers move to the `postgres-rw` service. authentik points its `postgresql.host` there and reads the shared role password; litellm's `DATABASE_URL` is rewritten to the new host and password; pgAdmin's server definition targets the read-write service. Ordering is expressed through split Kustomizations: the database Kustomization depends on the operator one, and the authentik and apps Kustomizations depend on the database one so no app reconciles before its role and database exist.

The cutover is a clean slate. The existing data is discarded by choice; authentik and litellm recreate their schemas on first boot against the freshly provisioned databases.

This retires the Bitnami `postgresql` HelmRelease and its Bitnami source, both `db-init` Jobs and their SOPS init secrets, and the standalone `litellm-db-init` Flux Kustomization.

## Options considered

- Keep Bitnami and the imperative db-init Jobs, hardening them into a CronJob for drift correction. This keeps a working setup but leaves schema provisioning as procedural state outside the chart, keeps each password duplicated across an init secret and a connection secret, and never gains self-healing roles. It treats the symptom rather than the missing abstraction.
- Crossplane with a `provider-sql`. This declares roles and databases as resources but bolts a second control plane and a generic SQL provider onto a server the cluster still has to run and back up separately, with no operator-level understanding of Postgres failover, backups, or instance lifecycle.
- CloudNativePG, chosen. It owns the server, the roles, and the databases as first-class declarative resources under one operator, reconciles them continuously, and folds password management into the role definition. It replaces the chart, both init Jobs, both init secrets, and the per-app Kustomization with a `Cluster`, two `Database` resources, and two basic-auth secrets.

## Consequences

Database provisioning is now declarative and self-healing: a role or database that is deleted or drifts is reconciled back, and a password change in the SOPS secret propagates to the role without a job run. The cost is a one-time data reset at cutover, accepted because both consumers rebuild their schemas on boot. CRD ordering is load-bearing and expressed through Flux Kustomization dependencies rather than a forced single apply, since the `Cluster`, `Database`, and managed-role resources cannot be validated before the operator's CRDs are installed. The role passwords live in basic-auth secrets that reconcile under the existing secrets Kustomization, so the database Kustomization that consumes them depends on it. The network policy that fronted the old chart pods by their Bitnami labels is rewritten to select the CNPG instance pods by `cnpg.io/cluster: postgres`, and the consumers' egress allows follow the same relabel. The stale n8n egress is removed.

Backups are deferred. Velero already snapshots the Longhorn volume, which covers the cluster at the storage layer; a Barman object-store backup that understands Postgres point-in-time recovery is a later addition once the operator is bedded in. Until then the recovery story for this cluster is the volume snapshot, the same as it was for the Bitnami PVC.

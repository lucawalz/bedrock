---
status: accepted
date: 2025-11-02
---

# 0008. Use Traefik as the cluster ingress

## Context

Traffic from the Cloudflare Tunnel has to land somewhere inside the cluster that routes by hostname to the right service. That ingress also has to terminate or pass through TLS and integrate with the certificate issuer. K3s ships Traefik by default, so the question was whether to keep it or replace it with something else.

## Decision

Traefik is the in-cluster ingress and reverse proxy, run as a Flux-managed Helm release in `kubernetes/infrastructure/controllers/onprem/traefik/` rather than the K3s-bundled copy, which is disabled. Traefik's IngressRoute CRDs and middleware cover the routing needs, and it works cleanly with the cert-manager issuer from [0006](0006-cert-manager-dns01.md). Keeping the tool K3s already standardizes on avoided introducing a second ingress for no real gain.

## Options considered

- Traefik, chosen. Already the K3s default, with IngressRoute CRDs, middleware, and a dashboard, and a clean fit with cert-manager.
- ingress-nginx. Widely used and well understood, but switching to it meant replacing a working default with no advantage that mattered here.
- HAProxy. Fast and capable, but lower-level for this use and without the CRD-driven routing that makes Traefik convenient.

## Consequences

Routing is declared as Kubernetes resources and lives in Git like everything else. Per-app basic-auth middleware was the first authentication layer in front of the internal dashboards and was retired by [0038](0038-authentik-sso-for-internal-dashboards.md) in favor of Authentik forward auth. The standing cost is the CRD lifecycle: the chart upgrades CRDs with `CreateReplace`, so a Traefik chart major bump can replace the IngressRoute CRDs and wipe existing IngressRoutes, which then have to be force-reconciled to recreate them.

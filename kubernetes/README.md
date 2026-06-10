# Kubernetes

Everything under `clusters/home/` is the live cluster state. Flux watches `main` and reconciles it, so changes land by committing rather than by running kubectl.

## Layout

```
clusters/home/
  flux-system/     Flux controllers (gotk-components) and the Git source (gotk-sync)
  config/          the Flux Kustomizations that build the cluster, plus cluster-settings
  namespaces/      namespace definitions
  sources/helm/    HelmRepository sources
  secrets/         SOPS-encrypted secrets (see its README)
  infrastructure/  networking, storage, databases, monitoring, rancher
  apps/            n8n and the LLM stack (ollama, open-webui, litellm)
```

`config/cluster-settings.yaml` holds the non-secret values substituted across manifests, currently the cluster domain and timezone.

## Reconciliation order

The root kustomization pulls in `flux-system` (the controllers and the Git source) and `config` (the set of Flux Kustomizations). Those Kustomizations apply in dependency order, and any layer whose dependencies are not ready waits instead of failing:

1. `cluster-sources` and `cluster-namespaces` have no dependencies. Sources defines the HelmRepositories every release pulls from; namespaces are created before anything lands in them.
2. `cluster-secrets` decrypts the SOPS secrets, after namespaces exist.
3. `cluster-infrastructure` applies networking, storage, databases, and monitoring, after sources, secrets, and namespaces.
4. `cluster-issuers` applies the cert-manager ClusterIssuers, after infrastructure.
5. `cluster-apps` applies n8n and the LLM stack, after infrastructure and issuers.

## Bootstrap

Flux manages itself. `clusters/home/kustomization.yaml` includes `flux-system`, so the controller versions and the Git source URL reconcile from this repo like any other resource. Upgrading Flux or changing the source is therefore a commit, not a re-bootstrap. A fresh cluster is brought up once, bootstrapped against a fork of this repository:

```
flux bootstrap github \
  --owner=<github-user> \
  --repository=<fork> \
  --path=kubernetes/clusters/home \
  --personal
```

## Adding a service

1. Add a namespace under `namespaces/` and list it in that kustomization.
2. If the chart comes from a new repository, add a HelmRepository under `sources/helm/`.
3. Create the workload under `apps/` or `infrastructure/` as a HelmRelease, and list it in the nearest kustomization.
4. For external access, add a Traefik IngressRoute for the hostname and map that hostname into the Cloudflare tunnel.
5. For any secret, encrypt it with SOPS into `secrets/` (see its README).

Commit to `main`, and Flux applies the change on its next pass.

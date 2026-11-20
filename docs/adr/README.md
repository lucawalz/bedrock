# Architecture decision records

These records describe the architecture of the bedrock cluster as it was rebuilt from git in November 2026. Each one states the context, the decision and its consequences, and stays short. A record that a later decision overturns is marked superseded and keeps its text.

The decision log from before the rebuild is kept in the [archive](archive/README.md) for its reasoning. It is no longer maintained, and the records below supersede it.

- [1. Reconcile the cluster from git with the Flux Operator](0001-reconcile-the-cluster-from-git-with-the-flux-operator.md) (accepted)
- [2. Declare every host with NixOS flakes](0002-declare-every-host-with-nixos-flakes.md) (accepted)
- [3. Run K3s as one server and two agents on the tailnet](0003-run-k3s-as-one-server-and-two-agents-on-the-tailnet.md) (accepted)
- [4. Keep a stable cluster CA under an offline root](0004-keep-a-stable-cluster-ca-under-an-offline-root.md) (accepted)
- [5. Keep host secrets in agenix and cluster secrets in SOPS](0005-keep-host-secrets-in-agenix-and-cluster-secrets-in-sops.md) (accepted)
- [6. Store volumes on Longhorn](0006-store-volumes-on-longhorn.md) (accepted)
- [7. Share one CloudNativePG cluster with per-app databases](0007-share-one-cloudnativepg-cluster-with-per-app-databases.md) (accepted)
- [8. Deny network traffic by default](0008-deny-network-traffic-by-default.md) (accepted)
- [9. Enforce workload policy with Kyverno](0009-enforce-workload-policy-with-kyverno.md) (accepted)
- [10. Sign in through Pocket ID and oauth2-proxy](0010-sign-in-through-pocket-id-and-oauth2-proxy.md) (accepted)
- [11. Serve through Traefik and a Cloudflare tunnel](0011-serve-through-traefik-and-a-cloudflare-tunnel.md) (accepted)
- [12. Back up off-site to Cloudflare R2 and test restores](0012-back-up-off-site-to-cloudflare-r2-and-test-restores.md) (accepted)
- [13. Keep each app self-contained and scaffold new ones](0013-keep-each-app-self-contained-and-scaffold-new-ones.md) (accepted)
- [14. Pin versions and update them with Renovate](0014-pin-versions-and-update-them-with-renovate.md) (accepted)
- [15. Observe with Prometheus, Loki and Tempo](0015-observe-with-prometheus-loki-and-tempo.md) (accepted)
- [16. Boot nodes through Secure Boot and unlock LUKS with the TPM](0016-boot-nodes-through-secure-boot-and-unlock-luks-with-the-tpm.md) (accepted)
- [17. Lock the tailnet to signed devices](0017-lock-the-tailnet-to-signed-devices.md) (accepted)
- [18. Keep passwords in Vaultwarden behind Pocket ID](0018-keep-passwords-in-vaultwarden-behind-pocket-id.md) (accepted)

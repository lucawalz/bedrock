# Security policy

This is a personal homelab repository. Secrets are committed only in encrypted form (agenix for host secrets, SOPS with age for Kubernetes secrets), and the cluster is reached through a Cloudflare Tunnel with no open inbound ports.

## Reporting a vulnerability

Report a suspected vulnerability privately through the "Report a vulnerability" form under the repository's Security tab, rather than opening a public issue. A maintainer will respond there.

## Supported versions

Only the `main` branch is maintained. It reflects the running cluster.

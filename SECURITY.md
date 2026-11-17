# Security policy

This is a personal homelab repository. Secrets are committed only in encrypted form (agenix for host secrets, SOPS with age for Kubernetes secrets), and the cluster is reached through a Cloudflare Tunnel with no open inbound ports.

## Reporting a vulnerability

Report a suspected vulnerability privately through the "Report a vulnerability" form at <https://github.com/lucawalz/bedrock/security/advisories/new>, rather than opening a public issue. Reports are acknowledged within 7 days. Coordinated disclosure follows within 90 days of the report, or earlier once a fix is deployed.

## Supported versions

Only the `main` branch is maintained. It reflects the running cluster.

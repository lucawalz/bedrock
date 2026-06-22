---
status: accepted
date: 2026-06-23
---

# 0052. Document the rack as code with RackPeek

## Context

The physical layout of the homelab lived in prose. [0016](0016-concrete-zoned-ip-scheme.md) settled the zoned IP scheme and [0050](0050-poe-switch-powers-the-router.md) recorded the switch port map in a table, but there was no single rendered view that tied the three Lenovo m920q nodes, the Raspberry Pi router, and the TP-Link TL-SG108PE switch together as one inventory. A rewire had a table to read but nothing to look at, and the hardware facts were spread across separate records.

RackPeek is a small self-hosted web UI and CLI for documenting home-lab and small-scale infrastructure. It reads a single `config.yaml` describing the inventory and renders it. It is licensed AGPL-3.0, which permits self-hosting, and ships as `aptacode/rackpeek` on Docker Hub. The catch is that RackPeek is built to manage state, not just display it: its CLI exposes `add`, `set`, `del`, and `rename` verbs and the web UI edits the same file, so by default the application writes its own `config.yaml` back to disk.

## Decision

Adopt RackPeek as the rendered rack-as-code view and keep the inventory under version control as the single source of truth. The `config.yaml` lives in the repository as a ConfigMap and is mounted read-only into the container. Edits happen in git and reconcile through Flux, not through the UI.

The read-only mount is the deliberate part. RackPeek's own model is UI-driven click-ops against a writable file, which on a GitOps cluster would mean two writers fighting over the same state: an operator editing in the browser and Flux reverting on the next reconcile, with the live inventory drifting from the repository in between. Mounting the ConfigMap read-only removes the second writer outright. The application still renders and serves; a write attempt fails at the filesystem rather than producing a change that silently disappears, which keeps the repository authoritative and the rendered view honest.

The inventory records the real hardware: the Pi gateway at 10.20.0.1 powered over PoE from switch port 2, the TL-SG108PE at 192.168.2.212 with the full port map from [0050](0050-poe-switch-powers-the-router.md), and master, worker-1, and worker-2 at 10.20.0.10 through .12 on VLAN 20 against switch ports 6, 7, and 8. The schema carries no per-port or per-host position field, so the port assignments and addresses are held in each resource's notes and labels.

The image is pinned to `v2.0.0` by digest. The deployment runs as the image's non-root user, drops all capabilities, and uses a read-only root filesystem with an `emptyDir` for the runtime's scratch space. Ingress is a Traefik `IngressRoute` for `rackpeek.syslabs.dev` behind the same Authentik forward-auth middleware the other internal dashboards use ([0008](0008-traefik-ingress.md), [0038](0038-authentik-sso-for-internal-dashboards.md)), so the inventory is reachable only after single sign-on.

## Options considered

- Let RackPeek own its `config.yaml` on a persistent volume and edit through the UI. Rejected: it puts the source of truth inside the cluster outside git, drifts from the repository, and on a Flux-reconciled cluster fights any committed copy. The whole point of rack-as-code is that the repository is authoritative.
- Keep the rack description in prose and ADR tables only. Workable and already in place, but it offers no rendered view and leaves the hardware facts scattered across records rather than collected in one inventory.
- Mount the ConfigMap writable so the UI can save. Rejected: it reintroduces the two-writer drift the read-only mount exists to prevent, for the sake of an editing path that git already provides more safely.

## Consequences

The rack is now described in one versioned file and rendered behind single sign-on, and a rewire has a picture to check against rather than three tables to cross-reference. Changing the inventory means committing to the repository, which is the same workflow as the rest of the cluster and leaves an audit trail. The cost is that RackPeek's native editing and CLI mutation are unavailable inside the cluster by design; an operator who wants those runs RackPeek separately against a scratch file and transcribes the result into the repository. Because the file is pinned and read-only, the rendered view cannot drift from what is committed.

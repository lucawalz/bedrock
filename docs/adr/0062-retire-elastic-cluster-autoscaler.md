---
status: accepted
date: 2026-07-06
---

# 0062. Retire the elastic cluster-autoscaler

## Context

[0041](0041-hetzner-autoscaling-native-provider.md) introduced the native `hetzner` cluster-autoscaler to give the home cluster elastic burst capacity: an `elastic` node group that scaled Hetzner VMs from zero on pending-pod pressure and back down when idle. That elastic capacity is no longer needed. On-demand capacity provisioned by the horizon tool covers the remaining requirement, and the standing autoscaler Deployment, its Helm chart repository, and its SOPS config secret are overhead for a path nothing exercises.

## Decision

Remove the cluster-autoscaler. On-demand reserved capacity provisioned by horizon directly through the hcloud API is the only remaining scaling path. The orphan-node reaper from [0026](0026-orphan-node-reaper.md), narrowed to its Longhorn-finalize pass in [0040](0040-reap-orphaned-longhorn-nodes.md), is kept, since horizon-driven teardown of a reserved node still strands a `nodes.longhorn.io` record that needs finalizing.

## Consequences

The home cluster no longer auto-scales on pending-pod pressure; capacity beyond the three bare-metal nodes is added and removed on demand through horizon. This supersedes the autoscaler portion of [0041](0041-hetzner-autoscaling-native-provider.md); its retirement of the Cluster-API-for-Hetzner stack still stands.

## Update 2026-08-02

The reaper this record kept was not in the state this record describes. It was retained as narrowed to the Longhorn-finalize pass, but the Node-deletion pass had never actually been removed and was still deleting nodes labelled `horizon.dev/pool=reserved` every ten minutes. [0071](0071-deploy-horizon-operator-from-published-chart.md) removes it and renames the CronJob to `longhorn-node-finalizer`. The reason for keeping the job is unchanged and is the reason given here: horizon-driven teardown of a reserved node still strands a `nodes.longhorn.io` record that needs finalizing.

Horizon is no longer only a workstation tool. Its operator runs in the cluster under [0071](0071-deploy-horizon-operator-from-published-chart.md) and owns orphan Node collection, which is what makes the reaper's first pass redundant rather than merely unused.

---
status: accepted, on-demand capacity premise superseded by 0081
date: 2026-07-06
---

# 0062. Retire the elastic cluster-autoscaler

## Context

[0041](0041-hetzner-autoscaling-native-provider.md) introduced the native `hetzner` cluster-autoscaler to give the home cluster elastic burst capacity: an `elastic` node group that scaled Hetzner VMs from zero on pending-pod pressure and back down when idle. That elastic capacity was no longer needed. On-demand capacity provisioned by the horizon tool covered the remaining requirement, and the standing autoscaler Deployment, its Helm chart repository, and its SOPS config secret were overhead for a path nothing exercised.

## Decision

Remove the cluster-autoscaler. On-demand reserved capacity provisioned by horizon directly through the hcloud API is the only remaining scaling path. The orphan-node reaper from [0026](0026-orphan-node-reaper.md), narrowed to its Longhorn-finalize pass in [0040](0040-reap-orphaned-longhorn-nodes.md), is kept, since horizon-driven teardown of a reserved node still strands a `nodes.longhorn.io` record that needs finalizing.

## Consequences

The home cluster no longer auto-scales on pending-pod pressure. This supersedes the autoscaler portion of [0041](0041-hetzner-autoscaling-native-provider.md); its retirement of the Cluster-API-for-Hetzner stack still stands.

The reaper this record kept was not in the state described. It was retained as narrowed to the Longhorn-finalize pass, but the Node-deletion pass had never actually been removed and was still deleting nodes labelled as reserved every ten minutes. [0071](0071-deploy-horizon-operator-from-published-chart.md) removes that pass and renames the job, and the reason for keeping the job is unchanged. Horizon is also no longer only a workstation tool: its operator runs in the cluster under the same record and owns orphan Node collection, which is what makes the reaper's first pass redundant rather than merely unused. The premise that made retiring the autoscaler safe is also gone. On-demand capacity through horizon closed with the Hetzner account, since [0081](0081-retire-the-hetzner-account.md) removes the provider configuration, its Kustomization, and the hcloud API egress rule, so there is no scaling path of any kind and capacity is the three bare-metal nodes. The decision to remove the autoscaler still stands on its own terms, because a controller reacting to load would have nothing to provision either, and the Longhorn-finalize job is unaffected.

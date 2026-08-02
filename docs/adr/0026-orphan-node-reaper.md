---
status: superseded by 0041 and 0071
date: 2026-06-15
---

# 0026. Prune orphan burst node objects with an in-cluster reaper

Superseded by [0041](0041-hetzner-autoscaling-native-provider.md). Introduced an in-cluster CronJob to prune orphan burst Node objects left by abrupt CAPI teardown. The native autoscaler provider deletes the server and Node together, so that pruning purpose is gone, but the reaper CronJob itself survives, narrowed to the Longhorn-finalize pass; see [0040](0040-reap-orphaned-longhorn-nodes.md) and [0041](0041-hetzner-autoscaling-native-provider.md).

## Update 2026-08-02

The narrowing described above was recorded but never carried out. The Node-deletion pass stayed in the manifest through the autoscaler's retirement in [0062](0062-retire-elastic-cluster-autoscaler.md) and kept running every ten minutes against nodes labelled `horizon.dev/pool=reserved`, with nothing left provisioning them that it needed to clean up after.

[0071](0071-deploy-horizon-operator-from-published-chart.md) removes it. Orphan Node collection belongs to the horizon operator, which knows each node's registration window and so cannot delete one that is still joining. The CronJob keeps only the Longhorn pass and is renamed accordingly. Nothing of this record's decision remains in the estate.

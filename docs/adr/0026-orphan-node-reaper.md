---
status: superseded by 0041
date: 2026-06-15
---

# 0026. Prune orphan burst node objects with an in-cluster reaper

Superseded by [0041](0041-hetzner-autoscaling-native-provider.md). Introduced an in-cluster CronJob to prune orphan burst Node objects left by abrupt CAPI teardown. The native autoscaler provider deletes the server and Node together, so that pruning purpose is gone, but the reaper CronJob itself survives, narrowed to the Longhorn-finalize pass; see [0040](0040-reap-orphaned-longhorn-nodes.md) and [0041](0041-hetzner-autoscaling-native-provider.md).

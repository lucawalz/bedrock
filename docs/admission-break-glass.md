# Admission break-glass

How to recover the cluster when an admission webhook refuses the writes needed to fix it.

Kyverno enforces the workload policies in [ADR 0009](adr/0009-enforce-workload-policy-with-kyverno.md), and several platform operators run their own webhooks. A webhook whose `failurePolicy` is `Fail` turns its own unavailability into a write outage for every resource it claims. The recovery is always the same: stop the API server consulting the broken webhook, repair the workload behind it, then restore enforcement.

Blast radius is set by two fields on the configuration object: `failurePolicy`, and the `namespaceSelector` deciding where the webhook is consulted. A `Fail` webhook with an empty selector reaches everywhere.

## Recognising the failure

The symptom is a write that fails with a message naming the webhook rather than the resource:

```
Internal error occurred: failed calling webhook "validate.kyverno.svc-fail": failed to call webhook: Post "https://kyverno-svc.kyverno.svc:443/...": context deadline exceeded
```

A policy rejection names the rule that refused and is a deliberate answer from a healthy webhook. A webhook failure names the transport. Only the second calls for this runbook.

Confirm which webhooks can block before changing anything:

```
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o 'custom-columns=NAME:.metadata.name,POLICY:.webhooks[*].failurePolicy'
```

## The webhooks that can block recovery

All of these are `failurePolicy: Fail`. The first row reaches across resource kinds and blocks general recovery; the rest claim only their own custom resources, so each blocks recovery of its own subsystem.

| Configuration | Owner | What it blocks while unavailable |
| --- | --- | --- |
| `kyverno-resource-validating-webhook-cfg` | Kyverno | Pods, deployments, daemonsets, jobs and cronjobs, in every namespace outside the webhook `namespaceSelector` |
| the remaining six `Fail` `kyverno-*` configurations | Kyverno | Kyverno's own policies, exceptions and global context entries |
| `longhorn-webhook-validator`, `longhorn-webhook-mutator` | Longhorn | Volumes, backups, backup targets and backing images, so volume and backup recovery |
| `cnpg-validating-webhook-configuration`, `cnpg-mutating-webhook-configuration` | CNPG operator | Clusters, backups, scheduled backups, databases and poolers, so database restore and failover changes |
| `metallb-webhook-configuration` | MetalLB | Address pools, BGP peers and advertisements, so load balancer addressing changes |
| `frr-k8s-validating-webhook-configuration` | frr-k8s | FRR configurations |
| `cert-manager-webhook` validating and mutating | cert-manager | `cert-manager.io` and `acme.cert-manager.io` resources, so certificate issuance and renewal |

The subsystem webhooks are circular: a Longhorn outage blocks the Longhorn writes needed to repair it, and the same holds for CNPG and MetalLB. The procedure below applies unchanged with the configuration name substituted.

The resource mutating webhook, `kyverno-resource-mutating-webhook-cfg`, is `Ignore`, because the only mutating policy sets `failurePolicy: Ignore`, so a Kyverno outage skips the mutation rather than blocking the write.

The Kyverno resource webhooks exclude `kube-system`, `kyverno`, and the recovery namespaces `flux-system`, `longhorn-system`, `cert-manager`, `metallb-system`, `monitoring` and `cnpg-system`, so recovery work inside those proceeds during a Kyverno outage. Work anywhere else does not.

## Disabling enforcement

Prefer relaxing the failure policy over deleting the configuration: the object, its rules and its CA bundle stay intact, and the owning controller overwrites the value when it reconciles.

Kyverno:

```
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o json \
  | jq '(.webhooks[].failurePolicy) = "Ignore"' | kubectl replace -f -
```

Without `jq`, `kubectl edit` the object and change each `failurePolicy` by hand.

## Deleting the configuration

Reserved for a webhook that is reachable but returns errors, or an object too large to edit under time pressure.

For Kyverno there is a simpler action than either. Kyverno removes its own resource webhook configurations when the admission controller shuts down gracefully, so scaling to zero disarms admission with no edit to any webhook object:

```
kubectl -n kyverno scale deployment kyverno-admission-controller --replicas=0
```

Scaling back up recreates them within about a second. It follows that a Kyverno outage only blocks writes when the pods die *without* shutting down cleanly, such as node loss, an OOM kill or a partition. A graceful scale-down cannot rehearse that failure, because it removes the very configurations the failure would leave behind.

Kyverno recreates all ten configurations on start, because it runs with `--autoUpdateWebhooks=true` and the chart ships no webhook templates. Deleting them is safe and self-healing:

```
kubectl delete validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -l webhook.kyverno.io/managed-by=kyverno
```

Restarting the admission controller rewrites them:

```
kubectl -n kyverno rollout restart deployment kyverno-admission-controller
```

## Repairing the backend

With enforcement relaxed, the blocked writes succeed. The usual causes are an unschedulable workload, a service with no ready endpoints, or an expired serving certificate.

```
kubectl -n kyverno get pods -l app.kubernetes.io/component=admission-controller
kubectl -n kyverno get endpoints kyverno-svc
```

No ready endpoints is a scheduling or health problem, not an admission problem. Kyverno runs two replicas with hard anti-affinity, so a single node loss leaves one serving.

## Restoring enforcement

A cluster left with `Ignore` policies is a cluster whose policies are advisory. Restarting the owning controller is the reliable route, because it rewrites its own configurations:

```
kubectl -n kyverno rollout restart deployment kyverno-admission-controller
```

Then confirm none was left relaxed:

```
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o json | jq -r '.items[] | . as $i | .webhooks[]
  | select(.failurePolicy=="Ignore") | "\($i.metadata.name) \(.name)"'
```

Six entries are `Ignore` by design and are expected in that output at rest. Anything beyond this set still needs restoring.

| Configuration | Webhook |
| --- | --- |
| `kube-prometheus-stack-admission` | `alertmanagerconfigsvalidate.monitoring.coreos.com` |
| `kube-prometheus-stack-admission` | `prometheusrulemutate.monitoring.coreos.com` |
| `kube-prometheus-stack-admission` | `prometheusrulevalidate.monitoring.coreos.com` |
| `kyverno-resource-mutating-webhook-cfg` | `mutate.kyverno.svc-ignore` |
| `kyverno-ttl-validating-webhook-cfg` | `kyverno-cleanup-controller.kyverno.svc` |
| `kyverno-verify-mutating-webhook-cfg` | `monitor-webhooks.kyverno.svc` |

## Known gaps

- `--webhookTimeout=5` reaches only the Kyverno resource and policy webhooks. The exception, CEL exception and global context webhooks, and the `kyverno-cleanup-*` and `kyverno-ttl-*` webhooks served by the cleanup controller, whose binary has no timeout flag, stay at 10 seconds.

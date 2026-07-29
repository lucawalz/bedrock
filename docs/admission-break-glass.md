# Admission break-glass

How to recover the cluster when an admission webhook refuses the writes needed to fix it.

A webhook whose `failurePolicy` is `Fail` turns its own unavailability into a write outage for every resource it claims. The recovery is always the same: stop the API server consulting the broken webhook, repair the workload behind it, then restore enforcement.

Blast radius is set by two fields on the configuration object: `failurePolicy`, and the `namespaceSelector` deciding where the webhook is consulted. A `Fail` webhook with an empty selector reaches everywhere.

## Recognising the failure

The symptom is a write that fails with a message naming the webhook rather than the resource:

```
Internal error occurred: failed calling webhook "validate.kyverno.svc-fail": failed to call webhook: Post "https://kyverno-svc.kyverno.svc:443/...": context deadline exceeded
```

```
Internal error occurred: failed calling webhook "rancher.cattle.io.secrets": ... connect: connection refused
```

A policy rejection names the rule that refused and is a deliberate answer from a healthy webhook. A webhook failure names the transport. Only the second calls for this runbook.

Confirm which webhooks can block before changing anything:

```
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o 'custom-columns=NAME:.metadata.name,POLICY:.webhooks[*].failurePolicy'
```

## The webhooks that can block recovery

All of these are `failurePolicy: Fail`. The first two rows reach across resource kinds and block general recovery; the rest claim only their own custom resources, so each blocks recovery of its own subsystem.

| Configuration | Owner | What it blocks while unavailable |
| --- | --- | --- |
| `rancher.cattle.io` validating and mutating | rancher-webhook | Secrets, namespaces, projects and RBAC cluster-wide, with an empty namespaceSelector |
| `kyverno-resource-validating-webhook-cfg`, `kyverno-resource-mutating-webhook-cfg` | Kyverno | Pods, deployments, daemonsets, jobs and cronjobs, in every namespace outside the webhook `namespaceSelector` |
| the remaining six `Fail` `kyverno-*` configurations | Kyverno | Kyverno's own policies, exceptions and global context entries |
| `longhorn-webhook-validator`, `longhorn-webhook-mutator` | Longhorn | Volumes, backups, backup targets and backing images, so volume and backup recovery |
| `cnpg-validating-webhook-configuration`, `cnpg-mutating-webhook-configuration` | CNPG operator | Clusters, backups, scheduled backups, databases and poolers, so database restore and failover changes |
| `metallb-webhook-configuration` | MetalLB | Address pools, BGP peers and advertisements, so load balancer addressing changes |
| `frr-k8s-validating-webhook-configuration` | frr-k8s | FRR configurations |
| `cert-manager-webhook` validating and mutating | cert-manager | `cert-manager.io` and `acme.cert-manager.io` resources, so certificate issuance and renewal |
| `capi-validating-webhook-configuration`, `capi-mutating-webhook-configuration` | CAPI | Cluster API resources only, which hold no workload in this estate |

The subsystem webhooks are circular: a Longhorn outage blocks the Longhorn writes needed to repair it, and the same holds for CNPG and MetalLB. The procedure below applies unchanged with the configuration name substituted.

The Kyverno resource webhooks exclude `kube-system`, `kyverno`, and the recovery namespaces `flux-system`, `longhorn-system`, `cert-manager`, `metallb-system`, `monitoring`, `velero` and `cnpg-system`, so recovery work inside those proceeds during a Kyverno outage. Work anywhere else does not.

The Rancher configuration has no such exclusion. Its `rancher.cattle.io.secrets` mutating webhook claims Secret CREATE, UPDATE and DELETE in every namespace, so while rancher-webhook is down no Secret can be written anywhere. That blocks cert-manager renewal, Flux SOPS decryption, CNPG and any Velero restore.

## Disabling enforcement

Prefer relaxing the failure policy over deleting the configuration: the object, its rules and its CA bundle stay intact, and the owning controller overwrites the value when it reconciles.

Kyverno:

```
kubectl get validatingwebhookconfiguration kyverno-resource-validating-webhook-cfg -o json \
  | jq '(.webhooks[].failurePolicy) = "Ignore"' | kubectl replace -f -
```

Rancher, which needs both configurations:

```
for k in validatingwebhookconfiguration mutatingwebhookconfiguration; do
  kubectl get $k rancher.cattle.io -o json \
    | jq '(.webhooks[].failurePolicy) = "Ignore"' | kubectl replace -f -
done
```

Without `jq`, `kubectl edit` the object and change each `failurePolicy` by hand. The field appears once per webhook entry, and the Rancher validating configuration carries 31.

## Deleting the configuration

Reserved for a webhook that is reachable but returns errors, or an object too large to edit under time pressure.

For Kyverno there is a simpler action than either. Kyverno removes its own resource webhook configurations when the admission controller shuts down gracefully, so scaling to zero disarms admission with no edit to any webhook object:

```
kubectl -n kyverno scale deployment kyverno-admission-controller --replicas=0
```

Scaling back up recreates them within about a second. It follows that a Kyverno outage only blocks writes when the pods die *without* shutting down cleanly, such as node loss, an OOM kill or a partition, and that a graceful scale-down cannot rehearse that failure, because it removes the very configurations the failure would leave behind.

Kyverno recreates all ten configurations on start, because it runs with `--autoUpdateWebhooks=true` and the chart ships no webhook templates. Deleting them is safe and self-healing:

```
kubectl delete validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -l webhook.kyverno.io/managed-by=kyverno
```

Restarting the admission controller rewrites them:

```
kubectl -n kyverno rollout restart deployment kyverno-admission-controller
```

The Rancher configurations are different. The chart creates both objects as empty shells and the binary writes the rules, failure policies and timeouts at runtime; whether it recreates an object deleted outright is not established. Take a copy first:

```
kubectl get validatingwebhookconfiguration rancher.cattle.io -o yaml > rancher-validating.yaml
kubectl get mutatingwebhookconfiguration rancher.cattle.io -o yaml > rancher-mutating.yaml
```

If the objects do not return after the webhook recovers, reapply those copies, or delete the `rancher-webhook` app so the systemcharts controller reinstalls it.

## Repairing the backend

With enforcement relaxed, the blocked writes succeed. The usual causes are an unschedulable workload, a service with no ready endpoints, or an expired serving certificate.

```
kubectl -n kyverno get pods -l app.kubernetes.io/component=admission-controller
kubectl -n cattle-system get pods -l app=rancher-webhook
kubectl -n kyverno get endpoints kyverno-svc
kubectl -n cattle-system get endpoints rancher-webhook
```

No ready endpoints is a scheduling or health problem, not an admission problem. Kyverno and rancher-webhook both run two replicas with hard anti-affinity, so a single node loss leaves one of each serving. The rancher-webhook replica count is imperative and is the one part Flux does not reconcile; see Restoring rancher-webhook.

## Restoring enforcement

A cluster left with `Ignore` policies is a cluster whose policies are advisory. Restarting the owning controller is the reliable route, because each rewrites its own configurations:

```
kubectl -n kyverno rollout restart deployment kyverno-admission-controller
kubectl -n cattle-system rollout restart deployment rancher-webhook
```

Then confirm none was left relaxed:

```
kubectl get validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -o json | jq -r '.items[] | . as $i | .webhooks[]
  | select(.failurePolicy=="Ignore") | "\($i.metadata.name) \(.name)"'
```

Ten entries are `Ignore` by design and are expected in that output at rest. Anything beyond this set still needs restoring.

| Configuration | Webhook |
| --- | --- |
| `kube-prometheus-stack-admission` | `alertmanagerconfigsvalidate.monitoring.coreos.com` |
| `kube-prometheus-stack-admission` | `prometheusrulemutate.monitoring.coreos.com` |
| `kube-prometheus-stack-admission` | `prometheusrulevalidate.monitoring.coreos.com` |
| `kyverno-ttl-validating-webhook-cfg` | `kyverno-cleanup-controller.kyverno.svc` |
| `kyverno-verify-mutating-webhook-cfg` | `monitor-webhooks.kyverno.svc` |
| `rancher.cattle.io` | `rancher.cattle.io.clusters.management.cattle.io` |
| `rancher.cattle.io` | `rancher.cattle.io.features.management.cattle.io` |
| `rancher.cattle.io` | `rancher.cattle.io.namespaces.create-kubesystem-only` |
| `rancher.cattle.io` | `rancher.cattle.io.podsecurityadmissionconfigurationtemplates.management.cattle.io` |
| `rancher.cattle.io` | `rancher.cattle.io.settings.management.cattle.io` |

## Restoring rancher-webhook

The chart contains no `replicas` field and no affinity values, so a second replica cannot be declared through Helm or reconciled by Flux. Reapply after any rebuild that reinstalls Rancher from scratch:

```
kubectl -n cattle-system patch deploy/rancher-webhook --type=merge -p '{
  "spec": {"replicas": 2, "template": {"spec": {"affinity": {"podAntiAffinity":
    {"requiredDuringSchedulingIgnoredDuringExecution": [{"labelSelector":
      {"matchLabels": {"app": "rancher-webhook"}},
      "topologyKey": "kubernetes.io/hostname"}]}}}}}}'
```

The change survives Rancher upgrades, because both fields are absent from the rendered manifest and Helm's three-way merge emits no patch for them. It does not survive a rebuild into an empty cluster.

Confirm two ready pods on two different nodes:

```
kubectl -n cattle-system get pods -l app=rancher-webhook -o wide
```

## Known gaps

- The rancher-webhook replica count and anti-affinity are imperative, for the reason above. Nothing detects their absence, so a rebuild silently returns to one replica until the command is reapplied.
- The Rancher webhook rules and failure policies are written by the binary at runtime and are not tunable through chart values, so enforcement scope cannot be narrowed declaratively.
- Whether the rancher-webhook binary recreates a deleted webhook configuration is unverified. Until it is, take a copy before deleting.
- The `kyverno-cleanup-*` and `kyverno-ttl-*` webhooks are served by the cleanup controller, whose binary has no timeout flag. They stay at a 10 second timeout while the rest of Kyverno runs at 5.

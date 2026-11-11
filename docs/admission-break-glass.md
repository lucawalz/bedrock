# Admission break-glass

How to recover the cluster when an admission webhook refuses the writes needed to fix it, and how to reach the admin UIs when sign-in through Pocket ID fails.

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

Namespaces are not in the table on purpose. Kyverno's resource webhooks also receive Namespace writes for `generate-network-policies`, and a `Fail` answer there would hold `cluster-namespaces` not-Ready during a Kyverno outage. `cluster-security`, which deploys Kyverno, depends on `cluster-namespaces`, so it could not heal that. The policy therefore sets `failurePolicy: Ignore`: a Kyverno outage lets the Namespace write through without its baseline policies. A namespace created during an outage is checked once Kyverno is back with `kubectl get netpol default-deny allow-dns -n <namespace>`, and if they are missing, reconciling `cluster-policies` re-runs generation for existing namespaces.

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

## Kyverno namespace NetworkPolicies

If the `kyverno` namespace's own NetworkPolicies cut Kyverno off from the API server or its webhook callers, every `Fail` Kyverno webhook times out, including the policy webhook that guards ClusterPolicy changes. A graceful scale-down cannot help either, because a controller with no API reach cannot remove its webhook configurations. Disarm admission first, with the label delete from [Deleting the configuration](#deleting-the-configuration):

```
kubectl delete validatingwebhookconfigurations,mutatingwebhookconfigurations \
  -l webhook.kyverno.io/managed-by=kyverno
```

Deleting the NetworkPolicies alone does not hold, because Flux re-applies them on its next reconcile. Stop Flux, then delete:

```
flux suspend kustomization cluster-security
flux suspend kustomization cluster-policies
kubectl -n kyverno delete networkpolicy --all
```

The `generate-network-policies` rules exclude the `kyverno` namespace by name, so nothing is generated there and the steps above are enough. Only if `kyverno` is ever removed from that list does a generated copy come back within seconds. In that case, after the delete above, also turn off `synchronize` on the generate rules (or delete the ClusterPolicy, which leaves the generated objects in every other namespace in place because the rules set `orphanDownstreamOnPolicyDelete`), then delete the NetworkPolicies again:

```
kubectl get clusterpolicy generate-network-policies -o json \
  | jq '(.spec.rules[].generate.synchronize) = false' | kubectl replace -f -
kubectl -n kyverno delete networkpolicy --all
```

Once Kyverno is healthy, resume both Kustomizations. Flux restores the NetworkPolicies and, where it was changed, the ClusterPolicy with `synchronize: true`. Kyverno recreates its webhook configurations on start:

```
flux resume kustomization cluster-policies
flux resume kustomization cluster-security
```

A NetworkPolicy outage in any other namespace needs none of this. NetworkPolicies are additive, so a temporary allow policy restores traffic at once without touching `default-deny`; delete it after the fix lands.

## Known gaps

- `--webhookTimeout=5` reaches only the Kyverno resource and policy webhooks. The exception, CEL exception and global context webhooks, and the `kyverno-cleanup-*` and `kyverno-ttl-*` webhooks served by the cleanup controller, whose binary has no timeout flag, stay at 10 seconds.

## Signing in without a passkey

Every forward-auth host signs in through Pocket ID ([ADR 0010](adr/0010-sign-in-through-pocket-id-and-oauth2-proxy.md)), and Pocket ID accepts passkeys only. A lost passkey therefore locks out every admin UI at once. Pocket ID's own CLI issues a one-time login link for an existing user without a passkey:

```
kubectl -n pocket-id exec deploy/pocket-id -- /app/pocket-id one-time-access-token <owner email>
```

The command prints a URL of the form `https://id.syslabs.dev/lc/<token>`, valid once and for one hour. Opening it from the LAN or the tailnet signs in to Pocket ID as that user, where the admin UI can register a new passkey for the owner. The link must be opened on `id.syslabs.dev`: Pocket ID binds its passkeys and session to that origin, so neither a passkey nor a session works through a `localhost` port-forward of Pocket ID itself.

## Reaching admin UIs without forward-auth

A port-forward reaches a Service directly, bypassing Traefik, forward-auth and the NetworkPolicies in front of it. These work while Pocket ID or oauth2-proxy is down:

| UI | Command | Local URL | Login |
| --- | --- | --- | --- |
| Grafana | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80` | `http://localhost:3000` | Grafana admin, `just login grafana` |
| Prometheus | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090` | `http://localhost:9090` | none |
| Alertmanager | `kubectl -n monitoring port-forward svc/kube-prometheus-stack-alertmanager 9093` | `http://localhost:9093` | none |
| Longhorn | `kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80` | `http://localhost:8080` | none |
| ntfy | `kubectl -n ntfy port-forward svc/ntfy 8081:80` | `http://localhost:8081` | read-only user `phone`, `just login ntfy` |
| Flux | `kubectl -n flux-system port-forward svc/flux-operator 9080` | `http://localhost:9080` | none |
| paperless-gpt | `kubectl -n paperless port-forward svc/paperless-gpt 8082:8080` | `http://localhost:8082` | none |
| LiteLLM | `kubectl -n litellm port-forward svc/litellm 4000` | `http://localhost:4000/ui` | LiteLLM master key, `just login litellm` |

Two UIs have no port-forward path:

- The Traefik dashboard is served only through its `api@internal` router. `kubectl get ingressroute -A` shows the routes it would.
- Homepage accepts only its own host name and the pod address, so a `localhost` request is refused. It carries no admin function.

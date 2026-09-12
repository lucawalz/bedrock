# Alert selector audit

How to prove that every alert rule the cluster has loaded can still fire, and what to do with what the audit reports.

## Why this is not a CI gate

`promtool` checks that a rule parses and that it behaves as its unit test says. It cannot check that the metric the rule selects exists, because the fixture supplies the series. A rule selecting a metric name nothing exports, a label value nothing emits, or a condition type no controller ever writes passes `promtool` exactly as a correct rule does, and then stays silent forever in production.

Answering that needs the live series database, so it needs cluster access, which a pull request runner does not have. `scripts/check-alert-selectors.sh` is therefore an operator gate rather than a CI one, and it is deliberately absent from `.github/workflows/k8s-validate.yaml`. Wiring it there would produce a job that cannot reach Prometheus and either fails on every pull request or, worse, is made to pass by skipping the work.

## Running it

From the dev shell, with a kubeconfig that reaches the cluster:

```
./scripts/check-alert-selectors.sh
```

It opens its own port-forward to `svc/kube-prometheus-stack-prometheus` and waits for readiness. To point it at a Prometheus that is already reachable, set the URL instead and it will not touch `kubectl`:

```
PROMETHEUS_URL=http://localhost:9090 ./scripts/check-alert-selectors.sh
```

Run it after Flux has reconciled a rule change, not before. The audit reads the rules Prometheus has loaded, so a rule that is committed but not yet applied is reported as declared and not loaded, which is accurate rather than a false alarm.

Run it after any chart upgrade that ships new mixin rules, and after any exporter is added, removed, or reconfigured. Those are the two moments a selector stops resolving without anything in this repository changing.

## What it checks

For every alerting and recording rule Prometheus has loaded, from this repository and from the kube-prometheus-stack mixin alike, it parses the expression through Prometheus's own parser and pulls out every vector and matrix selector. For each one:

- the metric name must have at least one series in the retention window
- every exact-match label matcher on that metric must have at least one series carrying that value

Regular-expression and negative matchers are not checked, because an expression such as `code=~"5.."` is meant to match nothing while the estate is healthy. Matchers against the empty string are not checked either, because they assert a label is absent and Prometheus never lists an empty value.

It also checks that every alert declared under `kubernetes/infrastructure/controllers/observability/alert-rules/` is present in the loaded rule set, so a file that failed to reconcile is a failure rather than an audit of stale content.

## What to do with a finding

A finding is one of three things, and the difference matters:

1. **The rule is wrong.** The metric was renamed, the label value was guessed, the bucket boundary does not exist, or the condition type is never emitted. Correct the rule.
2. **The rule is dead here.** The signal genuinely does not exist on this estate, usually because a mixin assumes a component k3s does not run. Disable it through `defaultRules.disabled` in `kubernetes/infrastructure/controllers/observability/kube-prometheus-stack/configmap-values.yaml` rather than leaving a guardrail that cannot fire, and replace it if a different metric carries the same signal.
3. **The selector is meant to be empty.** A failure condition nothing has hit, hardware the estate does not have, an exclusion clause with nothing to exclude. Record it in `scripts/alert-selector-allowlist.txt` with the reason, one entry per line as a bare metric name or `metric label=value`.

The allowlist is the point of the third case. An empty selector that is expected should be a written, reviewed statement rather than an absence nobody noticed.

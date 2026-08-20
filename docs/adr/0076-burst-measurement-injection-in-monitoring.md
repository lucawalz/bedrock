---
status: accepted
date: 2026-08-20
---

# 0076. Run the burst measurement harness's privileged injection Jobs in the monitoring namespace

## Context

`scripts/measure-burst.sh` measures how long a burst node takes to boot, join and disappear, and it does that by injecting scripted failures at a fixed offset after the node is ready. Three of its five scenarios need to act on the node itself: stop the watchdog unit, revoke the node token and restart the unit so the agent re-reads it, or both at once.

There is no way in over SSH. Horizon attaches only the Hetzner SSH keys named in `spec.hetzner.sshKeys` on the `ProviderConfig`, and the estate's `ProviderConfig` names none, so a burst node boots with no key the harness holds. [0072](0072-burst-node-credential-blast-radius.md) narrows TCP 22 on those nodes to a single administrative address at the Cloud Firewall anyway. On-node access therefore means a privileged pod with `hostPID` that enters the host namespaces with `nsenter`, scheduled onto the burst node and tolerating its taint.

The obvious namespace for that pod is `horizon-system`, where the operator and the lease live. It is also the one namespace where the pod cannot run. `horizon-system` carries `pod-security.kubernetes.io/enforce: baseline`, which rejects both `hostPID` and `privileged`. Behind that, three cluster-wide Kyverno policies in `Enforce` mode reject the same pod for three further reasons: `require-run-as-non-root`, `require-drop-all-capabilities` and `require-resources`. A server-side dry run of the Job in `horizon-system` on 20 August 2026 returned exactly those four objections.

`monitoring` accepts the same manifest unchanged. It carries `pod-security.kubernetes.io/enforce: privileged` because node-exporter needs the host namespaces for its own reasons, and it is listed in both `config.webhooks.namespaceSelector` and `config.resourceFiltersIncludeNamespaces` in the Kyverno HelmRelease, so Kyverno does not evaluate it at admission at all.

## Decision

Run the harness's injection Jobs in `monitoring`, and treat that as borrowed for the duration of the evaluation rather than as the harness's permanent home.

The pod is scheduled by `nodeSelector` onto the burst node and tolerates the burst taint, so the namespace it is declared in has no bearing on where it runs or what it touches. What the namespace decides is only whether admission lets it through. Given that, the choice is between borrowing a namespace that is already relaxed for an unrelated but similar reason, and relaxing a namespace that is not.

Relaxing `horizon-system` is the worse of the two. PodSecurity enforce is a namespace label, so there is no way to admit one Job without admitting every pod in the namespace, and `horizon-system` is where the delete-capable Hetzner credential from 0072 lives. The Kyverno side would need a `PolicyException` covering three policies on top. Both changes would be reconciled from Git, would outlive the measurement run that motivated them, and would weaken the posture of the one namespace the estate has the most reason to keep tight, all for a tool that is expected to be deleted.

Borrowing `monitoring` costs nothing to add and nothing to remove. The harness applies the Job, waits for it, reads its logs and deletes it, and leaves no declared object behind.

## Options considered

- Run the Job in `monitoring`, chosen. No policy changes, no manifests in Git, and nothing left over when the harness goes.
- Label `horizon-system` as PodSecurity privileged and add a Kyverno `PolicyException` for the three policies. Rejected. PodSecurity enforce cannot be scoped below the namespace, so this admits every future pod in the namespace holding the burst credential, and the exception would be committed to Git where it long outlives the measurement.
- Give the harness its own namespace, labelled privileged and excluded from Kyverno. Rejected for now. It is the correct shape if the harness becomes permanent, but it puts a new relaxed namespace and a new Kyverno exclusion into Git for a tool that has not yet earned either.
- Reach the node over SSH instead. Rejected. Horizon attaches no key the harness holds, and adding one would mean a key on every burst node plus a Cloud Firewall change, which is a larger and more permanent widening than the pod.

## Consequences

The harness now depends on the security posture of a namespace that has nothing to do with it. If `monitoring` is ever tightened, or dropped from Kyverno's exclusion lists, the `agent`, `both` and `node-token` scenarios stop being admitted, and the failure surfaces as a rejected Job rather than as anything that points at this decision. The script probes admission with a server-side dry run before it applies a lease, so that failure costs nothing, but the reason it failed will not be obvious from the error.

The borrow is wider than the PodSecurity label alone suggests. `monitoring` is outside Kyverno's admission webhook entirely, not merely exempt from the four policies that matter here, so the injection Job is unevaluated rather than evaluated and allowed. That is acceptable for a manifest this repository writes and reviews, and it would not be acceptable for a namespace running anything else.

If the harness outlives the evaluation, this decision has to be revisited rather than left to drift. The replacement is its own namespace with its own privileged label and its own Kyverno exclusion, which makes the relaxation visible in Git next to the thing that needs it, at the cost of one more relaxed namespace in the estate.

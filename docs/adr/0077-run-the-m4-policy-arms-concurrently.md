---
status: accepted
date: 2026-08-21
---

# 0077. Run the M4 policy arms concurrently, and make the quantum and its reference answer independent of arm order

## Context

M4 compares three ways of sizing a burst lease: a pinned `spec.size`, `spec.requirements` with `strategy: LowestPrice`, and the same requirements with `strategy: LowestPricePerCore`. Three runs of each at one replica, one run of each at three replicas, is twelve lease cycles and eighteen billed machines.

Hetzner rounds every partial instance-hour up, so a lease that lives ten minutes costs a full hour whether it runs alone or beside two others. Concurrency is therefore free in money and saves roughly three quarters of the campaign's wall clock. Two things stood in the way of taking it.

The first is targeting. `scripts/run-quantum.sh` selected burst nodes with `horizon.dev/pool=reserved` and tolerated the burst taint with `Exists`. Both are shared: every burst node in the estate carries the label, and the toleration matches any lease's taint because the taint's value is the lease name the toleration cannot know in advance. Three leases running side by side present three sets of nodes that all match, so a Job belonging to one arm could schedule onto another arm's machine. The measurement would still complete, still agree on a checksum, and still be wrong, because the elapsed time it reports would belong to a different instance type than the one its own lease latched into `status.instanceType`.

The second is the reference answer. The design calls for the baseline arm's checksum to be the reference the policy arms are checked against, which reads as an ordering constraint: run the baseline, take its checksum, then run the policy arms. That ordering also collides with calibration. The quantum's work parameter is derived rather than measured, honestly bracketed at three to nine minutes against a five minute target, so the first real boot is expected to produce a retune of `DEFAULT_SHARD_ITERATIONS`. Changing that parameter changes the checksum, so a checksum captured before the retune is not the reference for the runs after it.

## Decision

Pin each run's quantum to the node names of its own lease, and derive the reference checksum locally rather than from whichever arm happened to run first.

`run-quantum.sh` gains `--nodes`, which replaces the pool `nodeSelector` with a required `nodeAffinity` on `kubernetes.io/hostname` over an explicit list. The burst toleration stays, because the node is still tainted. `scripts/measure-policy.sh` reads the node names from its own lease's `status.instances[].nodeName` and passes exactly those, so a run can only ever measure its own machines. The pool selector remains the default for a single run that names no nodes.

The reference checksum is computed by running `scripts/quantum.py` once on the machine driving the campaign and caching it under the artefact root, keyed by seed and shard iterations. The quantum is deterministic integer arithmetic over a fixed input, so the answer does not depend on the machine that produces it; deriving it locally takes about half a minute rather than a boot. `--reference-checksum` still accepts a digest measured elsewhere, which is how the baseline arm's own checksum can be used instead when that is preferred.

## Options considered

- Pin to the lease's own node names and derive the reference locally, chosen. Every run is independent, so all twelve can be launched in any order or all at once.
- Serialise the campaign and keep the shared pool selector. Rejected. It quadruples the wall clock to avoid a hazard that a node list removes outright, and it does not solve the calibration problem, because the baseline checksum captured before the retune is still stale afterwards.
- Label each lease's nodes and select on that label. Rejected. It needs the operator to publish a per-lease node label, which is a change to horizon for a property the harness can already read from `status.instances[]`.
- Give each arm its own namespace so the Jobs cannot collide. Rejected. Namespaces do not constrain scheduling, so the Job would still land on another arm's node.
- Run the baseline first and feed its checksum to the policy arms. Rejected as the only mechanism, kept as an option. It orders the campaign around one arm and trusts that arm's answer, where a locally derived reference checks the baseline too.

## Consequences

A campaign is now twelve independent invocations rather than an ordered sequence, and the only pause that has to be observed is the calibration one: run the first baseline lease alone, read the suggested `DEFAULT_SHARD_ITERATIONS` from its summary, apply that one number, then launch the rest.

Pinning by hostname makes a run fail rather than mismeasure when its lease reports fewer nodes than replicas, because the Job has nowhere to schedule and the anti-affinity forbids doubling up. That is the intended failure: the alternative is a result that looks valid.

The locally derived reference makes the driver depend on `python3` on the machine running the campaign, which `nix develop` now provides. If the quantum ever stops being deterministic across machines, the local derivation becomes wrong in a way that presents as every arm failing its checksum, and the fix is to pass a measured digest with `--reference-checksum` instead.

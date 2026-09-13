---
status: accepted
date: 2026-08-21
---

# 0077. Run the M4 policy arms concurrently, and make the quantum and its reference answer independent of arm order

## Context

M4 compares three ways of sizing a burst lease: a pinned `spec.size`, `spec.requirements` with `strategy: LowestPrice`, and the same requirements with `strategy: LowestPricePerCore`. Three runs of each at one replica and one run of each at three replicas is twelve lease cycles and eighteen billed machines. Hetzner rounds every partial instance-hour up, so a lease that lives ten minutes costs a full hour whether it runs alone or beside two others, which makes concurrency free in money and saves roughly three quarters of the campaign's wall clock.

Two things stood in the way. The first is targeting: `scripts/run-quantum.sh` selected burst nodes with `horizon.dev/pool=reserved` and tolerated the burst taint with `Exists`, and both are shared, because every burst node carries the label and the toleration matches any lease's taint whose value is a lease name it cannot know in advance. Three leases running side by side present three sets of nodes that all match, so a Job belonging to one arm could schedule onto another arm's machine, and the measurement would still complete, still agree on a checksum, and still be wrong, because the elapsed time would belong to a different instance type than the one its own lease latched into `status.instanceType`. The second is the reference answer: the design calls for the baseline arm's checksum to be the reference the policy arms are checked against, which reads as an ordering constraint, and that ordering collides with calibration, because the quantum's work parameter is derived rather than measured and the first real boot is expected to produce a retune that changes the checksum.

## Decision

Pin each run's quantum to the node names of its own lease, and derive the reference checksum locally rather than from whichever arm happened to run first. `run-quantum.sh` gains `--nodes`, which replaces the pool `nodeSelector` with a required `nodeAffinity` on `kubernetes.io/hostname` over an explicit list, keeping the burst toleration because the node is still tainted. `scripts/measure-policy.sh` reads the node names from its own lease's `status.instances[].nodeName` and passes exactly those, so a run can only ever measure its own machines, and the pool selector remains the default for a single run that names no nodes. The reference checksum is computed by running `scripts/quantum.py` once on the machine driving the campaign and caching it under the artefact root, keyed by seed and shard iterations. The quantum is deterministic integer arithmetic over a fixed input, so the answer does not depend on the machine that produces it, and deriving it locally takes about half a minute rather than a boot. `--reference-checksum` still accepts a digest measured elsewhere, which is how the baseline arm's own checksum can be used instead when that is preferred.

## Options considered

- Pin to the lease's own node names and derive the reference locally, chosen. Every run is independent, so all twelve can be launched in any order or all at once.
- Serialise the campaign and keep the shared pool selector. Rejected. It quadruples the wall clock to avoid a hazard that a node list removes outright, and it does not solve the calibration problem, because the baseline checksum captured before the retune is still stale afterwards.
- Label each lease's nodes and select on that label. Rejected. It needs the operator to publish a per-lease node label, which is a change to horizon for a property the harness can already read from `status.instances[]`.
- Give each arm its own namespace so the Jobs cannot collide. Rejected. Namespaces do not constrain scheduling, so the Job would still land on another arm's node.
- Run the baseline first and feed its checksum to the policy arms. Rejected as the only mechanism and kept as an option. It orders the campaign around one arm and trusts that arm's answer, where a locally derived reference checks the baseline too.

## Consequences

A campaign is twelve independent invocations rather than an ordered sequence, and the only pause that has to be observed is the calibration one: run the first baseline lease alone, read the suggested shard iteration count from its summary, apply that one number, then launch the rest. Pinning by hostname makes a run fail rather than mismeasure when its lease reports fewer nodes than replicas, because the Job has nowhere to schedule and the anti-affinity forbids doubling up, which is the intended failure since the alternative is a result that looks valid. The locally derived reference makes the driver depend on `python3` on the machine running the campaign, which `nix develop` provides, and if the quantum ever stops being deterministic across machines the local derivation becomes wrong in a way that presents as every arm failing its checksum. No campaign can run today. [0081](0081-retire-the-hetzner-account.md) removed the `ProviderConfig` with the Hetzner account, so no lease can be created, and the harness stays in the repository dormant because the measurement work is expensive to reconstruct and cheap to keep.

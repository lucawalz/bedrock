---
status: accepted
date: 2026-08-03
---

# 0072. Bound the blast radius of burst nodes that carry a delete-capable Hetzner credential

## Context

[0071](0071-deploy-horizon-operator-from-published-chart.md) put the horizon operator in the cluster, and horizon leases ephemeral Hetzner servers to serve bursts of capacity. Those servers have public IPv4 addresses, join the cluster over Tailscale, and are expected to disappear when their lease expires.

The awkward part is how they disappear. Hetzner bills for a server for as long as the server object exists. Powering the machine off does not stop the meter, because the reserved capacity is only released on delete, and Hetzner offers no server-side lifetime after which an instance removes itself. A machine that has lost contact with the cluster therefore cannot stop costing money on its own unless it can call the Hetzner API and delete itself, and Hetzner tokens are project-scoped with no per-resource permissions. Horizon records this in the horizon repository's own ADR 0018, a separate record from bedrock's, which redesigned the provider seam around exactly this difference between clouds: the same requirement is free on AWS through shutdown behaviour, free on Google Compute Engine through a maximum run duration, and on Hetzner costs a delete-capable credential sitting on a disposable machine.

That record also prescribes the mitigation: a dedicated Hetzner project holding nothing but ephemeral capacity and the node images, so a leaked token can only destroy things that were going to be destroyed anyway. The estate does not have that. Everything horizon touches lives in the same Hetzner project the rest of the homelab uses, and moving to a separate one is not a configuration change.

The node image is a second reason the exposure is real rather than theoretical. Until commit `d50f70e` the image opened 6443, 10250 and 8472 on every interface, so a burst node published its apiserver port, its kubelet port and its VXLAN overlay to the internet for the whole of its life. That commit removed those rules, leaving only what `services.openssh.enable` opens, and the promoted snapshot was rebuilt from it, so the live image no longer carries them.

## Decision

Run burst nodes with a delete-capable Hetzner credential in the shared project, and bound what that credential and that public address can reach with layers that do not depend on the project boundary.

The credential is accepted because the alternative is worse. Without it a node that outlives its lease and cannot be reached bills until somebody notices, which is the failure the watchdog exists to prevent. Horizon's ownership guard is what keeps the credential narrow: its delete path refuses any instance that does not carry `horizon.dev/managed-by=horizon`, so a token taken off a node cannot be turned against anything the operator did not create, even though Hetzner would happily allow it.

The shared project is accepted for now rather than treated as fixed. The project holds no other servers, so the set of instances the guard would let a stolen token delete is the set of burst nodes. The node image is named after a content hash of the flake, the node modules and the Packer definition, so rebuilding it inside a dedicated project is a workflow run rather than a migration. That matters because Hetzner exposes moving a snapshot between projects only as a Console action with no API behind it, so a dedicated project is a rebuild, never a transfer.

This is recorded the way [0057](0057-cnpg-barman-dr-and-velero-scope.md) records the object storage keys, and for the same reason. That record had to be corrected once it turned out the separate CloudNativePG credential shared full control of both buckets with every other key, because Hetzner key pairs are project-wide and no bucket policy existed. The separation was organisational, not enforced. The same sentence applies here, so it is written down at the start instead of being discovered later: the boundary around burst capacity is horizon's label guard and the contents of the project, not a permission Hetzner is enforcing.

Two layers of network containment sit under that. Inside the guest, the node image no longer opens cluster ports on the public interface, and `tailscale0` is the only trusted interface, so the apiserver, the kubelet and the overlay are reachable over the tailnet and nowhere else. Outside the guest, a Hetzner Cloud Firewall named `horizon-burst` allows inbound TCP 22 from a single administrative address and inbound UDP 41641 for direct Tailscale connections, and denies everything else, which is what a Hetzner firewall does once any rule exists. The outer layer is the one that has to hold when the inner one does not, because cloud-init failing, an image reverting or a rule being dropped are all ways the in-guest firewall stops being what the repository says it is, and none of them reach a firewall enforced in Hetzner's network.

Attaching that firewall is not in force yet. It needs `spec.hetzner.firewalls` on the `ProviderConfig`, and the pinned chart is `0.1.0`, whose custom resource definition has no such property. The apiserver rejects the field outright rather than ignoring it, so setting it today would stop the `cluster-horizon-provider` Kustomization reconciling instead of quietly doing nothing. The field is therefore set in the same change that moves the chart to a release carrying it, and not before.

## Options considered

- A dedicated Hetzner project now, which is what horizon's record prescribes. It is the only option that makes the boundary something Hetzner enforces rather than something horizon respects. Deferred rather than rejected: it requires rebuilding the node image and the snapshot pipeline against a second project and second token, and the guard plus an otherwise empty project already covers the case it protects against. It becomes worth doing when the project stops being empty.
- Rely on the in-guest firewall alone and skip the Cloud Firewall. Rejected. Every way the image can be wrong is a way that firewall is absent, and a burst node is exactly the machine most likely to boot a stale image, since it is created from a snapshot by an operator rather than deployed by hand.
- Withhold the credential and let leases be reconciled only from inside the cluster. Rejected. It works while the cluster can see the node, which is the case that was never the problem. The credential exists for the partitioned node, and removing it turns a bounded cost into an open-ended one.
- Close TCP 22 in the image as well, so the public interface offers nothing. Rejected. A node whose Tailscale connection never comes up has no other way in, and that is the failure most likely to need a look at the console rather than a redeploy. The port stays open in the guest and is narrowed to one source address at the Cloud Firewall instead.

## Consequences

A Hetzner token that can delete servers lives on machines with public addresses, and that is now a recorded decision rather than an implementation detail. If one leaks, it can delete horizon-managed servers in the shared project. It cannot delete anything else, because horizon refuses to, and that refusal is code in an operator rather than a permission on the token.

TCP 22 is open on every burst node's public address. `services.openssh.enable` adds it through `openFirewall`, so it is not an oversight in the firewall block, and the containment for it is the Cloud Firewall source restriction rather than the guest. Anyone changing that administrative address has to change it in Hetzner, where the repository cannot see it and no review will catch it going stale.

Until the chart carries `spec.hetzner.firewalls`, only the in-guest layer is real, and a burst node created in that window has the public exposure the image gives it and nothing more. `horizon-burst` exists and is attached to nothing.

Adding the field early now fails in continuous integration rather than in the cluster. `scripts/gen-crd-schemas.sh` derives kubeconform schemas from the custom resource definitions this repository installs, including the ones in the pinned horizon chart, so a `ProviderConfig` field the chart does not define is rejected in a pull request. That closes the gap that made this a hazard: horizon's custom resources were previously skipped entirely by manifest validation, and a wrong field reached admission before anything noticed.

Moving to a dedicated project later stays cheap and stays a rebuild. Nothing here depends on the snapshot keeping its identity, only on the hash that names it being derivable from the repository.

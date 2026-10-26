---
status: accepted
date: 2026-10-26
---

# 0088. Keep Tailscale SSH off across the tailnet

## Context

On 25 October 2026 a researcher published the Tailworm report against Tailscale 1.104.2 and headscale 0.29.5. Its main chain starts from one compromised tailnet device that the policy allows to open a Tailscale SSH session with port forwarding. From there, forwarding reaches a root-only socket on the target, a root-owned socket can be swapped for the attacker's, and a race in a path check captures an enrollment key, so the attack repeats on every device the policy permits. No CVE and no fixed version existed at publication, and Tailscale had not issued a bulletin.

The estate never used Tailscale SSH. `RunSSH` is false on the Pi router, the three home nodes and the operator's Mac, no node has a `tailscale serve` configuration and none is an app connector. Hosts are reached over OpenSSH with keys only, root login without a password is refused, and that is the path [0074](0074-home-nodes-on-the-tailnet.md) relies on for control-plane-1. The tailnet policy, which is not tracked in this repository, still carried Tailscale's default `ssh` rule: any member could reach its own devices as any user, root included, in check mode. Nothing used it, but it was the one grant the report's chain needs.

## Decision

Remove the `ssh` section from the tailnet policy entirely, so Tailscale SSH grants nothing to anyone even if a device turns it on locally. Add an `sshTests` entry asserting that `tag:cluster` cannot reach root on `tag:cluster` over Tailscale SSH, and a policy test asserting that `tag:cluster` cannot reach the operator's Mac, so a policy edit that reintroduces either path fails on save.

Leave the nodes on Tailscale 1.98.8 for now. The current nixos-unstable ships 1.104.2, the exact version the report tested, so bumping nixpkgs would not remove any exposure, and the same bump carries k3s from 1.35 to 1.36, a Kubernetes minor upgrade that deserves its own change. Move once Tailscale publishes a fixed release, following the `flannel.1` rebind step in the disaster-recovery runbook, since a package bump restarts `tailscaled`.

## Options considered

- Remove the `ssh` section from the policy, chosen. It is enforced at the coordination server, covers every device including the Mac and phone, and needs no host rebuild.
- Also pin `--ssh=false` on every NixOS host. Rejected for now: with no `ssh` rules, a locally enabled Tailscale SSH server accepts nobody, so the flag adds a host-side setting that changes nothing the policy does not already enforce.
- Bump nixpkgs to pick up a newer Tailscale. Rejected for the reasons above: the newer version is the vulnerable one, and the bump is a cluster upgrade in disguise.
- Enable Tailnet Lock. Deferred rather than rejected. In the report it stopped the final step, where the attacker enrolls a machine of their own. It also turns every rebuilt or re-enrolled host into a manual signing step and adds disablement secrets to hold safely. With Tailscale SSH granting nothing, the chain never starts, and the reusable per-host auth keys that would make enrollment cheap are already due for revocation under the runbook.
- Scope the member grant down from `*`. Out of scope. The report's chain does not use it once Tailscale SSH is off, and narrowing it risks locking the operator out, as the policy itself notes.

## Consequences

Tailscale SSH is not available anywhere on the tailnet, and turning it on later needs a policy change as well as a device setting, which is the intended friction. A compromised tailnet device can still reach any host's OpenSSH on port 22, but needs a key to get anywhere, which is the same exposure as before the report.

The policy remains outside the repository, so this record is the only trace of the change. The reusable per-host auth keys the runbook lists are still valid until 3 November and should be revoked now that every node has enrolled, independently of this record.

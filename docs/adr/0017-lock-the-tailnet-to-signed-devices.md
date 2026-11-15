---
status: accepted
date: 2026-11-15
---

# 0017. Lock the tailnet to signed devices

## Context

The four tagged hosts and the admin devices reach each other over the tailnet, and the access policy grants the admin everything. A device that gets onto the tailnet, for example with a leaked auth key or through a compromised account, is trusted by the coordination server alone. [0088 in the archive](archive/0088-keep-tailscale-ssh-off-across-the-tailnet.md) deferred Tailnet Lock for the cost of manual signing and of holding the disablement secrets. This record supersedes that deferral.

## Decision

- Tailnet Lock is enabled with `tailscale lock init`. The trusted signers are the Mac and the owner's iPhone. The Mac signs with the CLI and the iPhone through the Tailscale app. `init` takes the Tailnet Lock key of the node it runs on, so the Mac's key is always among them, and it signs every existing node, so nothing is locked out when the lock turns on.
- `init` generates 10 disablement secrets, and the command's stdout is redirected straight onto the stick at `/Volumes/bedrock-keys/bedrock/tailnet-lock-disablements.txt`. Nothing is written to the Mac's SSD. `init` also generates the support disablement secret (`--gen-disablement-for-support`), which lets Tailscale support disable the lock.
- A reinstalled or newly joined host is locked out until a signer runs `tailscale lock sign <node-key>` for it. Signed auth keys are not used, because Tailscale advises against them.
- Tailnet Lock and device approval are mutually exclusive, so device approval stays off. Key expiry is off on the four tagged devices, and a signed node's key rotation needs no new signature.
- The runbooks for signing and for losing both signers are in [Admission break-glass](../admission-break-glass.md#tailnet-lock) and [Disaster recovery](../disaster-recovery.md).

## Consequences

- A device that joins without a signature reaches nothing, whatever auth key it holds.
- Every rebuilt host is a manual sign step, and a host that joins but is not signed looks like a network fault until `tailscale lock status` shows it as locked out.
- The stick holds the only copies of the disablement secrets. Losing all of them, while the support secret is unused, leaves the tailnet unrecoverable without Tailscale support.
- The iPhone is an online signer, not an offline one: it is a normal node that holds a signing key and signs through the app. Its loss is covered by the Mac, and the loss of both is covered by a disablement secret from the stick.
- The support secret lets Tailscale support disable the lock permanently. The lock cannot be re-enabled afterwards through that path. The trade-off is accepted as the last resort when every other secret is gone.
- `tailscale lock disable <secret>` turns the lock off for the whole tailnet and makes the used secret public, so each use burns one of the 10. The lock is then re-initialised with new signers and new secrets on the stick.

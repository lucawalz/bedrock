---
status: accepted
date: 2026-11-13
---

# 0016. Boot nodes through Secure Boot and unlock LUKS with the TPM

## Context

The three nodes stand in a home without physical access control. Their root filesystems were plain ext4, so a removed disk exposed the host SSH keys, which decrypt every agenix secret, and the K3s datastore. The systemd-boot editor was the only guard on the kernel command line, and nothing checked that the kernel and initrd were the ones the flake built. The nodes run unattended and have to come back after a power cut without anyone at a keyboard.

## Decision

- The nodes boot through [lanzaboote](https://github.com/nix-community/lanzaboote), pinned to a tagged release in `flake.nix`. It replaces systemd-boot and signs a unified kernel image per generation with Secure Boot keys created by `sbctl` and read from `/var/lib/sbctl`. The keys are generated once, kept on the `bedrock-keys` stick and placed on a node at install time; nothing generates or enrols keys on its own. The router does not change.
- disko formats the root partition as LUKS2 named `cryptroot`, with discards allowed, and ext4 inside it. The initrd crypttab entry carries `tpm2-device=auto`, so stage 1 unlocks from the TPM and falls back to a prompt on the console.
- lanzaboote's measured boot stays off. Its systemd-pcrlock policy needs the TPM2 PolicyAuthorizeNV command, which the firmware TPM of the m920q does not support: the first install stopped at "Installing Lanzaboote" with "TPM2 does not support PolicyAuthorizeNV command, refusing." All three nodes are the same model. `configurationLimit` stays at 4 to bound the unified kernel images on the ESP.
- The TPM slot is bound to fixed PCRs 0 and 7 and needs no PIN because the nodes are unattended. PCR 0 holds the firmware code. PCR 7 holds the Secure Boot state and the authority that verified the boot loader, so a boot with Secure Boot off or through a Microsoft-signed loader changes it. PCR 4 is not bound: Secure Boot already limits the boot chain to binaries signed with the estate keys, and a fixed PCR 4 would break the unlock on every rebuild. After the install, with Secure Boot enabled and the node booted once on the signed generation, on each node:

  ```
  systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/disk/by-partlabel/disk-main-root
  systemd-cryptenroll --recovery-key /dev/disk/by-partlabel/disk-main-root
  systemd-cryptenroll --wipe-slot=password /dev/disk/by-partlabel/disk-main-root
  ```

  The recovery key is written to the `bedrock-keys` stick, one file per host, and the install passphrase is wiped last.

## Consequences

- A removed disk is ciphertext. A disabled Secure Boot, other keys in the firmware or a boot loader not signed with the estate keys leave the TPM sealed, and the node waits at the console prompt. A changed kernel, initrd or command line is not measured into a bound PCR; Secure Boot refuses an unsigned unified kernel image instead.
- A NixOS rebuild changes only PCR 4, which is not bound, so it needs no re-enrolment. A firmware update changes PCR 0, and a change to the Secure Boot keys changes PCR 7; the next boot then asks for the recovery key from the stick at the node's console. Once booted, the TPM slot is re-enrolled:

  ```
  systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=0+7 /dev/disk/by-partlabel/disk-main-root
  ```

- Losing the recovery key and the TPM state together loses the node's disk. The node is then reinstalled and its data comes back from the Longhorn replicas on the other nodes and the R2 backups ([0012](0012-back-up-off-site-to-cloudflare-r2-and-test-restores.md)).
- The boot loader editor stays off, as it was under systemd-boot. Under Secure Boot the lanzaboote stub also ignores a command line passed by the boot loader.
- The flake describes the encrypted layout, so a node still on plain ext4 must be reinstalled with nixos-anywhere, not switched. `scripts/deploy-nodes.sh` checks every node's root device first and refuses to rebuild anything unless all of them boot from `/dev/mapper/cryptroot`.
- control-plane-1 no longer pins filesystem UUIDs; disko's partition labels name its disks like those of the workers.

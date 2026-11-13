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
- Measured boot is on with PCRs 0, 4 and 7: firmware code, the boot loader and lanzaboote stub (which covers the kernel, initrd and command line), and the Secure Boot policy. lanzaboote predicts the PCR state of every generation on the ESP with systemd-pcrlock and writes the policy to `/var/lib/systemd/pcrlock.json`, so a rebuild needs no re-enrolment. pcrlock allows at most four generations on the ESP, and `configurationLimit` is 4.
- The TPM slot is bound to the pcrlock policy, not to fixed PCR values, and needs no PIN because the nodes are unattended. After the install, with Secure Boot enabled and the node booted once on the signed generation, `systemd-pcrlock is-supported` must print `yes`, and then on each node:

  ```
  systemd-cryptenroll --tpm2-device=auto --tpm2-pcrlock=/var/lib/systemd/pcrlock.json /dev/disk/by-partlabel/disk-main-root
  systemd-cryptenroll --recovery-key /dev/disk/by-partlabel/disk-main-root
  systemd-cryptenroll --wipe-slot=password /dev/disk/by-partlabel/disk-main-root
  ```

  The recovery key is written to the `bedrock-keys` stick, one file per host, and the install passphrase is wiped last. If `is-supported` does not print `yes`, the node is not enrolled and this record is revisited; there is no silent fallback to plain PCR binding.

## Consequences

- A removed disk is ciphertext. A changed kernel, initrd or command line, a disabled Secure Boot or other keys in the firmware leave the TPM sealed, and the node waits at the console prompt.
- A NixOS rebuild changes only PCR 4, which the predicted policy already covers. A firmware update changes PCR 0, and a change to the Secure Boot keys changes PCR 7; the next boot then asks for the recovery key from the stick at the node's console. Once booted, the pcrlock services record the new measurements and update the policy in place, so later boots unlock from the TPM again. The update in place is as documented by lanzaboote and not yet observed on these nodes.
- Losing the recovery key and the TPM state together loses the node's disk. The node is then reinstalled and its data comes back from the Longhorn replicas on the other nodes and the R2 backups ([0012](0012-back-up-off-site-to-cloudflare-r2-and-test-restores.md)).
- systemd-pcrlock is marked experimental by systemd, which is why the recovery key is enrolled before the passphrase is wiped.
- lanzaboote's loader configuration takes the systemd-boot editor default, so the editor is on. Under Secure Boot the lanzaboote stub ignores a command line passed by the boot loader; without Secure Boot it measures it into PCR 4, which seals the TPM.
- The flake describes the encrypted layout, so a node still on plain ext4 must be reinstalled with nixos-anywhere, not switched. `scripts/deploy-nodes.sh` checks every node's root device first and refuses to rebuild anything unless all of them boot from `/dev/mapper/cryptroot`.
- control-plane-1 no longer pins filesystem UUIDs; disko's partition labels name its disks like those of the workers.

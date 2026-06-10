# Host secrets

NixOS host secrets are encrypted with agenix. Each secret is encrypted to the SSH host keys of the machines that need it, so a node decrypts its own secrets at boot using its existing host key. There is no shared passphrase and nothing to distribute by hand.

`secrets.nix` lists the recipient public keys and which secret each one can open. The only secret today is the K3s cluster join token, readable by the three nodes and the admin key:

```nix
"k3s-token.age".publicKeys = [ master worker-1 worker-2 luca ];
```

## Adding a secret or a node

1. Collect the new host's public key from `/etc/ssh/ssh_host_ed25519_key.pub`, or with `ssh-keyscan -t ed25519 <hostname>`.
2. Add it to the recipient list in `secrets.nix`.
3. Create or re-encrypt the secret with `agenix -e secrets/<name>.age`.
4. Reference it from a NixOS module with `age.secrets.<name>.file = "${secretsDir}/<name>.age"`.

Burst nodes do not use agenix. Their join token and server address are written into `/etc/horizon` during provisioning, because the machine does not exist yet when the secret is first needed.

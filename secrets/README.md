# NixOS Secrets (agenix)

This directory contains encrypted secrets for NixOS system-level configuration.

## Encryption

Secrets are encrypted using **agenix** with age keys derived from SSH host keys.

## Structure

- `secrets.nix` - Maps secret files to their authorized public keys
- `*.age` - Encrypted secret files

## Adding a Secret

1. Add the secret to `secrets.nix`:
   ```nix
   {
     "my-secret.age".publicKeys = [ master worker-1 luca ];
   }
   ```

2. Create/encrypt the secret:
   ```bash
   agenix -e secrets/my-secret.age
   ```

3. Edit the secret (opens in editor):
   ```bash
   agenix -e secrets/my-secret.age
   ```

## Current Secrets

- `k3s-token.age` - K3s cluster join token

## Getting Public Keys

Get a host's SSH public key:
```bash
ssh-keyscan -t ed25519 master
```

Or from the machine itself:
```bash
cat /etc/ssh/ssh_host_ed25519_key.pub
```


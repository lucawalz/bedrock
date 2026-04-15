# secrets

NixOS-level secrets encrypted with [agenix](https://github.com/ryantm/agenix). Each secret is encrypted against the SSH host keys of the nodes that need to decrypt it, plus the admin key.

## Current secrets

| File | Used by |
|---|---|
| `k3s-token.age` | All nodes — cluster join token |

## Adding a secret

1. Declare it in `secrets.nix`:
   ```nix
   "my-secret.age".publicKeys = [ master worker-1 worker-2 luca ];
   ```

2. Create and edit it:
   ```bash
   agenix -e secrets/my-secret.age
   ```

3. Reference it in a NixOS module:
   ```nix
   age.secrets.my-secret.file = "${secretsDir}/my-secret.age";
   ```

## Getting a node's public key

```bash
ssh-keyscan -t ed25519 <hostname>
# or on the node:
cat /etc/ssh/ssh_host_ed25519_key.pub
```

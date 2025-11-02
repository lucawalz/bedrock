# Secrets Management Guide

This homelab uses two secret management systems:
- **agenix** for NixOS system-level secrets
- **SOPS** for Kubernetes secrets

## NixOS Secrets (agenix)

### Location

Secrets are stored in `secrets/` directory:
- `secrets/secrets.nix` - Maps secrets to authorized public keys
- `secrets/*.age` - Encrypted secret files

### Adding a Secret

1. **Get host public keys**:

   ```bash
   # From the host machine
   cat /etc/ssh/ssh_host_ed25519_key.pub
   
   # Or remotely
   ssh-keyscan -t ed25519 master
   ```

2. **Add to secrets.nix**:

   ```nix
   let
     master = "ssh-ed25519 AAAAC3...";
     worker-1 = "ssh-ed25519 AAAAC3...";
     luca = "ssh-ed25519 AAAAC3...";
   in
   {
     "k3s-token.age".publicKeys = [ master worker-1 luca ];
     "my-new-secret.age".publicKeys = [ master worker-1 luca ];
   }
   ```

3. **Create/encrypt the secret**:

   ```bash
   agenix -e secrets/my-new-secret.age
   # Enter the secret content, save and exit
   ```

4. **Reference in NixOS config**:

   ```nix
   age.secrets.my-secret = {
     file = ../../secrets/my-new-secret.age;
     mode = "0400";
     owner = "root";
     group = "root";
   };
   ```

### Editing a Secret

```bash
agenix -e secrets/k3s-token.age
```

This decrypts the file, opens it in your editor, and re-encrypts on save.

### Accessing Secrets at Runtime

Decrypted secrets are available at `/run/agenix/` on the target machine:

```bash
# Example: K3s token
sudo cat /run/agenix/k3s-token
```

### Rotating a Secret

1. Edit the secret: `agenix -e secrets/my-secret.age`
2. Update the secret content
3. Rebuild NixOS: `sudo nixos-rebuild switch --flake .#master`
4. The new secret will be automatically decrypted and deployed

### Adding a New Host

1. Get the host's SSH public key
2. Add to `secrets.nix` as a variable
3. Add the key to relevant secrets' `publicKeys` list
4. Re-encrypt secrets if needed

## Kubernetes Secrets (SOPS)

### Location

Encrypted Kubernetes secrets are in:
- `kubernetes/clusters/home/secrets/*.sops.yaml`

### Setup SOPS

1. **Generate age key** (if not exists):

   ```bash
   age-keygen -o ~/.config/sops/age/keys.txt
   ```

2. **Get public key**:

   ```bash
   cat ~/.config/sops/age/keys.txt | grep public | cut -d: -f2
   ```

3. **Add to `.sops.yaml`**:

   ```yaml
   creation_rules:
     - path_regex: kubernetes/.*/secrets/.*\.sops\.yaml$
       encrypted_regex: ^(data|stringData)$
       age: age1xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
   ```

### Adding a Kubernetes Secret

1. **Create Secret manifest**:

   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: cloudflare-api-token
     namespace: networking
   type: Opaque
   stringData:
     api-token: your-api-token-here
   ```

2. **Encrypt with SOPS**:

   ```bash
   sops --encrypt --in-place kubernetes/clusters/home/secrets/cloudflare-api-token.yaml
   ```

3. **Rename to .sops.yaml**:

   ```bash
   mv cloudflare-api-token.yaml cloudflare-api-token.sops.yaml
   ```

4. **Add to kustomization.yaml**:

   ```yaml
   resources:
     - cloudflare-api-token.sops.yaml
   ```

### Editing a Kubernetes Secret

```bash
# Edit encrypted secret
sops kubernetes/clusters/home/secrets/my-secret.sops.yaml

# Or use justfile
just sops-edit kubernetes/clusters/home/secrets/my-secret.sops.yaml
```

### Using Secrets in HelmRelease

Reference secrets in HelmRelease values:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2beta1
kind: HelmRelease
metadata:
  name: external-dns
spec:
  values:
    cloudflare:
      apiTokenSecretRef:
        name: cloudflare-api-token
        key: api-token
```

## Best Practices

1. **Never commit unencrypted secrets** - Use `.gitignore` to exclude plaintext secrets
2. **Rotate regularly** - Especially for production-like setups
3. **Limit access** - Only authorize keys that need access
4. **Backup secrets** - Encrypted secrets are safe to backup, but keep backups secure
5. **Document secrets** - Keep a record (outside git) of what secrets exist

## Troubleshooting

### "No decryption key found"

- Check that host's SSH key is in `secrets.nix`
- Verify the key matches the actual host key
- For SOPS, check `.sops.yaml` has correct age key

### "Permission denied" when reading secrets

- Check file permissions in age.secrets config
- Verify owner/group settings
- Ensure service user has access

### SOPS decryption fails

- Verify age key is in `~/.config/sops/age/keys.txt`
- Check `.sops.yaml` has correct age public key
- Ensure SOPS version is compatible


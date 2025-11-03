# Secrets Management Reference

This document covers comprehensive secrets management using agenix for NixOS and SOPS for Kubernetes.

## Overview

The homelab uses a two-tier secrets management approach:
- **agenix** - For NixOS system secrets (K3s tokens, SSH keys, etc.)
- **SOPS** - For Kubernetes application secrets (database passwords, API keys, etc.)

Both use age encryption with different key management strategies.

## NixOS Secrets with agenix

### How agenix Works

agenix encrypts secrets using age and SSH host keys:
1. Secrets are encrypted with SSH public keys
2. Only machines with matching private keys can decrypt
3. Secrets are automatically decrypted at boot time
4. Decrypted secrets are available in `/run/agenix/`

### Setting Up agenix

#### 1. Install agenix

```bash
# In your development environment
nix develop  # agenix is included in the flake
```

#### 2. Configure SSH Keys

Edit `secrets/secrets.nix` with your SSH keys:

```nix
let
  # Host SSH keys (get with: ssh-keyscan -t ed25519 hostname)
  master = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAbc... root@master";
  worker-1 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAdef... root@worker-1";
  
  # Personal keys (for managing secrets)
  yourname = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAghi... you@laptop";
  
  # Groups for easier management
  allHosts = [ master worker-1 ];
  admins = [ yourname ];
in
{
  # K3s cluster token (shared across all nodes)
  "k3s-token.age".publicKeys = allHosts ++ admins;
  
  # Host-specific secrets
  "master-cert.age".publicKeys = [ master ] ++ admins;
  "worker-cert.age".publicKeys = [ worker-1 ] ++ admins;
}
```

#### 3. Create Secrets

```bash
# Create a new secret
agenix -e secrets/k3s-token.age

# Edit existing secret
agenix -e secrets/k3s-token.age

# List all secrets
agenix -l
```

#### 4. Use Secrets in NixOS Configuration

```nix
# In a NixOS module
{ config, ... }:
{
  # Define the secret
  age.secrets.k3s-token = {
    file = ../secrets/k3s-token.age;
    owner = "root";
    group = "root";
    mode = "0400";
  };

  # Use the secret
  services.k3s.tokenFile = config.age.secrets.k3s-token.path;
}
```

### Common agenix Patterns

#### Database Passwords

```nix
# secrets/secrets.nix
"postgres-password.age".publicKeys = [ master ] ++ admins;

# In NixOS configuration
age.secrets.postgres-password = {
  file = ../secrets/postgres-password.age;
  owner = "postgres";
  group = "postgres";
  mode = "0400";
};

services.postgresql = {
  enable = true;
  authentication = ''
    local all postgres peer
    local all all md5
  '';
  initialScript = pkgs.writeText "postgres-init" ''
    ALTER USER postgres PASSWORD '$(cat ${config.age.secrets.postgres-password.path})';
  '';
};
```

#### SSH Keys

```nix
# For service SSH keys
age.secrets.backup-ssh-key = {
  file = ../secrets/backup-ssh-key.age;
  owner = "backup";
  group = "backup";
  mode = "0600";
};

users.users.backup = {
  openssh.authorizedKeys.keyFiles = [ config.age.secrets.backup-ssh-key.path ];
};
```

#### API Tokens

```nix
# For service API tokens
age.secrets.cloudflare-token = {
  file = ../secrets/cloudflare-token.age;
  owner = "acme";
  group = "acme";
  mode = "0400";
};

security.acme.certs."example.com" = {
  dnsProvider = "cloudflare";
  credentialsFile = config.age.secrets.cloudflare-token.path;
};
```

## Kubernetes Secrets with SOPS

### How SOPS Works

SOPS encrypts YAML files while preserving structure:
1. Only values are encrypted, keys remain readable
2. Uses age keys for encryption
3. Integrates with Kubernetes via sops-secrets-operator
4. Supports key rotation and multiple recipients

### Setting Up SOPS

#### 1. Generate Age Keys

```bash
# Create age key for SOPS (different from SSH keys)
mkdir -p ~/.config/sops/age
age-keygen -o ~/.config/sops/age/keys.txt

# Display public key
cat ~/.config/sops/age/keys.txt | grep "# public key:"
```

#### 2. Configure SOPS

Create `.sops.yaml` in repository root:

```yaml
creation_rules:
  - path_regex: kubernetes/.*\.sops\.yaml$
    age: age1234567890abcdef...  # Your age public key
  - path_regex: kubernetes/.*\.sops\.yml$
    age: age1234567890abcdef...
```

#### 3. Install SOPS Secrets Operator

```yaml
# kubernetes/clusters/home/infrastructure/sops/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - namespace.yaml
  - https://github.com/isindir/sops-secrets-operator/deploy/crds
  - https://github.com/isindir/sops-secrets-operator/deploy
```

#### 4. Create Age Secret in Cluster

```bash
# Create secret with your age private key
kubectl create secret generic sops-age \
  --namespace=sops \
  --from-file=keys.txt=$HOME/.config/sops/age/keys.txt
```

### Creating SOPS Secrets

#### Method 1: Encrypt Existing Secret

```bash
# Create regular Kubernetes secret
kubectl create secret generic my-app-secret \
  --namespace=web \
  --from-literal=database-password=supersecret \
  --from-literal=api-key=abc123 \
  --dry-run=client -o yaml > secret.yaml

# Encrypt with SOPS
sops --encrypt --input-type=yaml --output-type=yaml secret.yaml > secret.sops.yaml
rm secret.yaml
```

#### Method 2: Create Encrypted Secret Directly

```bash
# Create template
cat > secret.sops.yaml << EOF
apiVersion: v1
kind: Secret
metadata:
    name: my-app-secret
    namespace: web
type: Opaque
data:
    database-password: supersecret
    api-key: abc123
EOF

# Encrypt
sops --encrypt --input-type=yaml --output-type=yaml secret.sops.yaml > temp && mv temp secret.sops.yaml
```

#### Method 3: Interactive Editing

```bash
# Create and edit encrypted secret
sops secret.sops.yaml
```

### Using SOPS Secrets

#### Standard Kubernetes Secret

```yaml
# kubernetes/clusters/home/apps/web/my-app/secret.sops.yaml
apiVersion: v1
kind: Secret
metadata:
    name: my-app-secret
    namespace: web
type: Opaque
data:
    database-password: ENC[AES256_GCM,data:Tr7o1...,tag:W23=,type:str]
    api-key: ENC[AES256_GCM,data:CwE4O...,tag:tNHV,type:str]
```

#### SopsSecret Custom Resource

```yaml
# kubernetes/clusters/home/apps/web/my-app/sopssecret.yaml
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: my-app-sopssecret
  namespace: web
spec:
  secretTemplates:
    - name: my-app-secret
      stringData:
        database-password: "{{ .database_password }}"
        api-key: "{{ .api_key }}"
      labels:
        app: my-app
      type: Opaque
  template:
    data:
      database_password: ENC[AES256_GCM,data:Tr7o1...,tag:W23=,type:str]
      api_key: ENC[AES256_GCM,data:CwE4O...,tag:tNHV,type:str]
```

### Advanced SOPS Patterns

#### Multi-Environment Secrets

```yaml
# .sops.yaml
creation_rules:
  - path_regex: kubernetes/clusters/home/.*\.sops\.yaml$
    age: age1home123...
  - path_regex: kubernetes/clusters/staging/.*\.sops\.yaml$
    age: age1staging456...
  - path_regex: kubernetes/clusters/prod/.*\.sops\.yaml$
    age: age1prod789...
```

#### Shared Secrets

```yaml
# kubernetes/clusters/home/secrets/shared/database.sops.yaml
apiVersion: isindir.github.com/v1alpha3
kind: SopsSecret
metadata:
  name: shared-database
  namespace: shared-secrets
spec:
  secretTemplates:
    - name: postgres-credentials
      stringData:
        username: "{{ .postgres_username }}"
        password: "{{ .postgres_password }}"
        host: "{{ .postgres_host }}"
      type: Opaque
  template:
    data:
      postgres_username: ENC[AES256_GCM,data:dGVzdA==,tag:W23=,type:str]
      postgres_password: ENC[AES256_GCM,data:Tr7o1...,tag:W23=,type:str]
      postgres_host: ENC[AES256_GCM,data:bG9jYWxob3N0,tag:tNHV,type:str]
```

## Key Management

### SSH Key Rotation

When rotating SSH keys for agenix:

1. **Generate new SSH keys** on target hosts
2. **Update secrets/secrets.nix** with new public keys
3. **Re-encrypt all secrets**:
   ```bash
   # Re-encrypt all secrets with new keys
   find secrets -name "*.age" -exec agenix -r {} \;
   ```
4. **Deploy updated configuration**
5. **Verify secrets decrypt** on target hosts

### Age Key Rotation

When rotating age keys for SOPS:

1. **Generate new age key**:
   ```bash
   age-keygen -o ~/.config/sops/age/keys-new.txt
   ```

2. **Update .sops.yaml** with new public key
3. **Re-encrypt all SOPS files**:
   ```bash
   find kubernetes -name "*.sops.yaml" -exec sops updatekeys {} \;
   ```

4. **Update cluster secret**:
   ```bash
   kubectl delete secret sops-age -n sops
   kubectl create secret generic sops-age \
     --namespace=sops \
     --from-file=keys.txt=$HOME/.config/sops/age/keys-new.txt
   ```

5. **Restart SOPS operator**:
   ```bash
   kubectl rollout restart deployment sops-secrets-operator -n sops
   ```

### Backup and Recovery

#### Backup Keys

```bash
# Backup agenix SSH keys
cp ~/.ssh/id_ed25519* /secure/backup/location/

# Backup SOPS age keys
cp ~/.config/sops/age/keys.txt /secure/backup/location/sops-age-key.txt

# Backup encrypted secrets (they're in git, but good practice)
tar -czf secrets-backup.tar.gz secrets/ kubernetes/*/secrets/
```

#### Recovery Process

```bash
# Restore SSH keys
cp /secure/backup/location/id_ed25519* ~/.ssh/
chmod 600 ~/.ssh/id_ed25519
chmod 644 ~/.ssh/id_ed25519.pub

# Restore SOPS keys
mkdir -p ~/.config/sops/age
cp /secure/backup/location/sops-age-key.txt ~/.config/sops/age/keys.txt
chmod 600 ~/.config/sops/age/keys.txt

# Test decryption
agenix -d secrets/k3s-token.age
sops -d kubernetes/clusters/home/secrets/example.sops.yaml
```

## Troubleshooting

### agenix Issues

**Cannot decrypt secret**:
```bash
# Check if SSH key matches
ssh-keyscan -t ed25519 hostname
# Compare with secrets/secrets.nix

# Test decryption manually
agenix -d secrets/k3s-token.age

# Check file permissions
ls -la /run/agenix/
```

**Secret not available at runtime**:
```bash
# Check agenix service
systemctl status agenix

# Check secret definition
nix-instantiate --eval -E '(import <nixpkgs/nixos> {}).config.age.secrets'
```

### SOPS Issues

**Cannot decrypt SOPS file**:
```bash
# Check age key
cat ~/.config/sops/age/keys.txt

# Test decryption
sops -d kubernetes/clusters/home/secrets/example.sops.yaml

# Check .sops.yaml configuration
sops -d --config .sops.yaml kubernetes/clusters/home/secrets/example.sops.yaml
```

**SOPS operator not working**:
```bash
# Check operator logs
kubectl logs -n sops deployment/sops-secrets-operator

# Check age secret in cluster
kubectl get secret sops-age -n sops -o yaml

# Verify SopsSecret resources
kubectl get sopssecrets -A
kubectl describe sopssecret -n namespace secret-name
```

### Permission Issues

**Wrong file ownership**:
```bash
# Check agenix secret permissions
ls -la /run/agenix/

# Fix in NixOS configuration
age.secrets.my-secret = {
  file = ../secrets/my-secret.age;
  owner = "correct-user";
  group = "correct-group";
  mode = "0400";
};
```

## Security Best Practices

### Key Security

- **Never commit private keys** to git
- **Use different keys** for different environments
- **Rotate keys regularly** (annually or after compromise)
- **Backup keys securely** with proper access controls
- **Use hardware security modules** for production environments

### Secret Hygiene

- **Minimize secret scope** - only give access to what's needed
- **Use service accounts** instead of user credentials where possible
- **Audit secret access** regularly
- **Remove unused secrets** promptly
- **Use short-lived tokens** when possible

### Operational Security

- **Monitor secret access** with audit logs
- **Alert on secret changes** or access anomalies
- **Use separate keys** for different environments
- **Implement break-glass procedures** for emergency access
- **Document secret recovery procedures**

## Integration Examples

### Database Connection

```nix
# NixOS side (agenix)
age.secrets.postgres-password.file = ../secrets/postgres-password.age;

services.postgresql = {
  enable = true;
  initialScript = pkgs.writeText "init" ''
    CREATE USER myapp WITH PASSWORD '$(cat ${config.age.secrets.postgres-password.path})';
  '';
};
```

```yaml
# Kubernetes side (SOPS)
apiVersion: v1
kind: Secret
metadata:
  name: postgres-credentials
  namespace: web
type: Opaque
data:
  username: ENC[AES256_GCM,data:bXlhcHA=,tag:W23=,type:str]
  password: ENC[AES256_GCM,data:Tr7o1...,tag:W23=,type:str]
  host: ENC[AES256_GCM,data:cG9zdGdyZXM=,tag:tNHV,type:str]
```

### API Integration

```nix
# NixOS side - API token for system service
age.secrets.monitoring-token = {
  file = ../secrets/monitoring-token.age;
  owner = "prometheus";
  mode = "0400";
};

services.prometheus.extraFlags = [
  "--web.config.file=${pkgs.writeText "web-config.yml" ''
    basic_auth_users:
      admin: $(cat ${config.age.secrets.monitoring-token.path})
  ''}"
];
```

```yaml
# Kubernetes side - API credentials for applications
apiVersion: v1
kind: Secret
metadata:
  name: external-api-credentials
  namespace: web
type: Opaque
data:
  api-key: ENC[AES256_GCM,data:YWJjMTIz,tag:W23=,type:str]
  api-secret: ENC[AES256_GCM,data:ZGVmNDU2,tag:tNHV,type:str]
```

This comprehensive secrets management setup ensures that sensitive data is properly encrypted, access-controlled, and auditable across both the NixOS infrastructure and Kubernetes applications.
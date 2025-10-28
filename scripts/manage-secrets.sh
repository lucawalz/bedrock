#!/bin/bash

# Helper script for managing sops-encrypted secrets

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

show_help() {
    echo "Usage: $0 [COMMAND] [OPTIONS]"
    echo ""
    echo "Commands:"
    echo "  encrypt-all     Encrypt all .yaml files that contain secrets"
    echo "  decrypt FILE    Decrypt a specific sops-encrypted file"
    echo "  edit FILE       Edit a sops-encrypted file"
    echo "  create-git-secret USERNAME TOKEN  Create and encrypt git auth secret"
    echo "  create-cf-secret TOKEN             Create and encrypt Cloudflare API secret
  create-tunnel-secret TOKEN        Create and encrypt Cloudflare tunnel secret"
    echo ""
    echo "Examples:"
    echo "  $0 encrypt-all"
    echo "  $0 decrypt kubernetes/infrastructure/flux-system/git-auth-secret.yaml"
    echo "  $0 edit kubernetes/infrastructure/cert-manager/cloudflare-secret.yaml"
    echo "  $0 create-git-secret myusername ghp_xxxxxxxxxxxx"
    echo "  $0 create-cf-secret your-cloudflare-api-token
  $0 create-tunnel-secret your-tunnel-token"
}

encrypt_all() {
    echo "🔐 Encrypting all secret files..."
    
    # Find and encrypt all secret files
    find "$PROJECT_ROOT/kubernetes" -name "*secret*.yaml" -type f | while read -r file; do
        if ! sops -d "$file" >/dev/null 2>&1; then
            echo "  Encrypting: $file"
            sops -e -i "$file"
        else
            echo "  Already encrypted: $file"
        fi
    done
    
    echo "✅ All secrets encrypted"
}

decrypt_file() {
    local file="$1"
    if [[ -z "$file" ]]; then
        echo "❌ Please specify a file to decrypt"
        exit 1
    fi
    
    echo "🔓 Decrypting: $file"
    sops -d "$file"
}

edit_file() {
    local file="$1"
    if [[ -z "$file" ]]; then
        echo "❌ Please specify a file to edit"
        exit 1
    fi
    
    echo "✏️  Editing: $file"
    sops "$file"
}

create_git_secret() {
    local username="$1"
    local token="$2"
    
    if [[ -z "$username" || -z "$token" ]]; then
        echo "❌ Please provide both username and token"
        exit 1
    fi
    
    local secret_file="$PROJECT_ROOT/kubernetes/infrastructure/flux-system/git-auth-secret.yaml"
    
    echo "🔐 Creating Git authentication secret..."
    
    kubectl create secret generic flux-system \
        --from-literal=username="$username" \
        --from-literal=password="$token" \
        --namespace=flux-system \
        --dry-run=client -o yaml > "$secret_file"
    
    sops -e -i "$secret_file"
    
    echo "✅ Git secret created and encrypted: $secret_file"
}

create_cf_secret() {
    local token="$1"
    
    if [[ -z "$token" ]]; then
        echo "❌ Please provide Cloudflare API token"
        exit 1
    fi
    
    local secret_file="$PROJECT_ROOT/kubernetes/infrastructure/cert-manager/cloudflare-secret.yaml"
    
    echo "🔐 Creating Cloudflare API secret..."
    
    kubectl create secret generic cloudflare-api-token-secret \
        --from-literal=api-token="$token" \
        --namespace=cert-manager \
        --dry-run=client -o yaml > "$secret_file"
    
    sops -e -i "$secret_file"
    
    echo "✅ Cloudflare secret created and encrypted: $secret_file"
}

create_tunnel_secret() {
    local token="$1"
    
    if [[ -z "$token" ]]; then
        echo "❌ Please provide Cloudflare tunnel token"
        exit 1
    fi
    
    local secret_file="$PROJECT_ROOT/kubernetes/infrastructure/cloudflare-tunnel/tunnel-secret.yaml"
    
    echo "🔐 Creating Cloudflare tunnel secret..."
    
    kubectl create secret generic cloudflare-tunnel-secret \
        --from-literal=tunnel-token="$token" \
        --namespace=cloudflare-tunnel \
        --dry-run=client -o yaml > "$secret_file"
    
    sops -e -i "$secret_file"
    
    echo "✅ Cloudflare tunnel secret created and encrypted: $secret_file"
}

case "$1" in
    encrypt-all)
        encrypt_all
        ;;
    decrypt)
        decrypt_file "$2"
        ;;
    edit)
        edit_file "$2"
        ;;
    create-git-secret)
        create_git_secret "$2" "$3"
        ;;
    create-cf-secret)
        create_cf_secret "$2"
        ;;
    create-tunnel-secret)
        create_tunnel_secret "$2"
        ;;
    create-longhorn-auth)
        create_longhorn_auth "$2" "$3"
        ;;
    create-postgres-auth)
        create_postgres_auth "$2" "$3"
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "❌ Unknown command: $1"
        echo ""
        show_help
        exit 1
        ;;
esac

create_longhorn_auth() {
    local username="$1"
    local password="$2"
    
    if [[ -z "$username" || -z "$password" ]]; then
        echo "❌ Please provide both username and password"
        exit 1
    fi
    
    local secret_file="$PROJECT_ROOT/kubernetes/infrastructure/longhorn/auth-secret.yaml"
    
    echo "🔐 Creating Longhorn basic auth secret..."
    
    # Generate htpasswd hash
    local htpasswd_entry=$(htpasswd -nb "$username" "$password")
    
    kubectl create secret generic longhorn-auth \
        --from-literal=users="$htpasswd_entry" \
        --namespace=longhorn-system \
        --dry-run=client -o yaml > "$secret_file"
    
    sops -e -i "$secret_file"
    
    echo "✅ Longhorn auth secret created and encrypted: $secret_file"
}

create_postgres_auth() {
    local postgres_password="$1"
    local user_password="$2"
    
    if [[ -z "$postgres_password" || -z "$user_password" ]]; then
        echo "❌ Please provide both postgres and user passwords"
        exit 1
    fi
    
    local secret_file="$PROJECT_ROOT/kubernetes/infrastructure/postgres/auth-secret.yaml"
    
    echo "🔐 Creating Postgres authentication secret..."
    
    kubectl create secret generic postgres-auth \
        --from-literal=postgres-password="$postgres_password" \
        --from-literal=user-password="$user_password" \
        --namespace=postgres \
        --dry-run=client -o yaml > "$secret_file"
    
    sops -e -i "$secret_file"
    
    echo "✅ Postgres auth secret created and encrypted: $secret_file"
}
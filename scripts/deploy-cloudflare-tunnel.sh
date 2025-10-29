#!/bin/bash

# Deploy Cloudflare Tunnel with SOPS decryption

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TUNNEL_DIR="$PROJECT_ROOT/kubernetes/infrastructure/cloudflare-tunnel"

echo "🚀 Deploying Cloudflare Tunnel..."

# Apply non-encrypted resources
echo "📦 Applying namespace and configmap..."
kubectl apply -f "$TUNNEL_DIR/namespace.yaml"
kubectl apply -f "$TUNNEL_DIR/configmap.yaml"

# Decrypt and apply secret
echo "🔐 Decrypting and applying tunnel secret..."
sops -d "$TUNNEL_DIR/tunnel-secret.yaml" | kubectl apply -f -

# Apply deployment
echo "🚀 Applying deployment..."
kubectl apply -f "$TUNNEL_DIR/deployment.yaml"

echo "✅ Cloudflare Tunnel deployed successfully!"
echo ""
echo "Monitor with: kubectl get pods -n cloudflare-tunnel -w"
#!/bin/bash

# Fix Longhorn disk configuration for both nodes
echo "🔧 Configuring Longhorn disks..."

# Configure master node disk
kubectl patch node.longhorn.io master -n longhorn-system --type='merge' -p='{
  "spec": {
    "disks": {
      "default-disk-master": {
        "allowScheduling": true,
        "evictionRequested": false,
        "path": "/var/lib/longhorn",
        "storageReserved": 1073741824,
        "tags": []
      }
    }
  }
}'

# Configure worker-1 node disk  
kubectl patch node.longhorn.io worker-1 -n longhorn-system --type='merge' -p='{
  "spec": {
    "disks": {
      "default-disk-worker-1": {
        "allowScheduling": true,
        "evictionRequested": false,
        "path": "/var/lib/longhorn",
        "storageReserved": 1073741824,
        "tags": []
      }
    }
  }
}'

echo "✅ Longhorn disk configuration applied"
echo "🔄 Restarting Longhorn manager pods..."

kubectl rollout restart daemonset longhorn-manager -n longhorn-system

echo "✅ Done! Check status with: kubectl get nodes.longhorn.io -n longhorn-system"
#!/bin/bash
# Kubernetes Cluster Restore Script
# Restores etcd snapshot and certificates from backup

set -euo pipefail

# Configuration
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/backup/k8s-backups}"
MASTER_NODE_NAME="${MASTER_NODE_NAME:-master-node}"
MASTER_NODE_IP="${MASTER_NODE_IP:-192.168.4.100}"

if [ $# -eq 0 ]; then
    echo "Usage: $0 <backup-directory>"
    echo ""
    echo "Available backups:"
    ls -lhtr "$BACKUP_ROOT/" 2>/dev/null | grep "^d" | tail -10
    echo ""
    echo "Example:"
    echo "  $0 $BACKUP_ROOT/latest"
    echo "  $0 $BACKUP_ROOT/20251010-133000"
    echo ""
    echo "Configuration (set via environment variables):"
    echo "  BACKUP_ROOT=$BACKUP_ROOT"
    echo "  MASTER_NODE_NAME=$MASTER_NODE_NAME"
    echo "  MASTER_NODE_IP=$MASTER_NODE_IP"
    exit 1
fi

BACKUP_DIR="$1"

if [ ! -d "$BACKUP_DIR" ]; then
    echo "ERROR: Backup directory not found: $BACKUP_DIR"
    exit 1
fi

if [ ! -f "${BACKUP_DIR}/etcd-snapshot.db" ]; then
    echo "ERROR: etcd snapshot not found in backup directory"
    exit 1
fi

echo "⚠️  WARNING: This will restore your cluster from backup!"
echo "This is a DESTRUCTIVE operation that will:"
echo "  - Stop all cluster operations"
echo "  - Replace current etcd data with backup"
echo "  - Restart the cluster"
echo ""
echo "Backup to restore from:"
cat "${BACKUP_DIR}/backup-info.txt" 2>/dev/null || echo "No backup info found"
echo ""
read -p "Are you ABSOLUTELY sure? (type 'yes' to continue): " confirm

if [ "$confirm" != "yes" ]; then
    echo "Restore cancelled."
    exit 0
fi

echo ""
echo "=== Starting Cluster Restore ==="
echo ""

# 1. Stop kubelet to prevent interference
echo "Step 1: Stopping kubelet..."
sudo systemctl stop kubelet
sleep 5

# 2. Move current etcd data as backup
echo "Step 2: Backing up current etcd data..."
TIMESTAMP=$(date +%s)
if [ -d /var/lib/etcd ]; then
    sudo mv /var/lib/etcd /var/lib/etcd.backup.${TIMESTAMP}
    echo "Current etcd data saved to: /var/lib/etcd.backup.${TIMESTAMP}"
fi

# 3. Restore etcd snapshot
echo "Step 3: Restoring etcd snapshot..."
sudo ETCDCTL_API=3 etcdctl snapshot restore \
  "${BACKUP_DIR}/etcd-snapshot.db" \
  --data-dir=/var/lib/etcd \
  --name="$MASTER_NODE_NAME" \
  --initial-cluster="$MASTER_NODE_NAME=https://$MASTER_NODE_IP:2380" \
  --initial-advertise-peer-urls="https://$MASTER_NODE_IP:2380"

# 4. Fix permissions
echo "Step 4: Fixing permissions..."
sudo chown -R root:root /var/lib/etcd

# 5. Restore PKI certificates if they exist in backup
if [ -d "${BACKUP_DIR}/pki-backup" ]; then
    echo "Step 5: Restoring PKI certificates..."
    sudo cp -r "${BACKUP_DIR}/pki-backup"/* /etc/kubernetes/pki/
else
    echo "Step 5: No PKI backup found, skipping..."
fi

# 6. Start kubelet
echo "Step 6: Starting kubelet..."
sudo systemctl start kubelet

echo ""
echo "=== Restore Process Complete ==="
echo ""
echo "Waiting 30 seconds for cluster to stabilize..."
sleep 30

echo ""
echo "Checking cluster status..."
echo ""

# Check node status
echo "Node Status:"
kubectl get nodes || echo "⚠️  Nodes not ready yet, wait a bit longer..."
echo ""

# Check control plane pods
echo "Control Plane Pods:"
kubectl get pods -n kube-system | grep -E "etcd|apiserver|controller|scheduler" || echo "⚠️  Control plane not ready yet..."
echo ""

# Check all pods
echo "All Pods (first 20):"
kubectl get pods -A | head -20 || echo "⚠️  Unable to get pods yet..."
echo ""

echo "✅ Restore completed!"
echo ""
echo "Next steps:"
echo "  1. Check cluster health: kubectl get nodes"
echo "  2. Verify pods are running: kubectl get pods -A"
echo "  3. Check your applications are working"
echo ""
echo "If there are issues, you can restore the previous etcd data:"
echo "  sudo systemctl stop kubelet"
echo "  sudo rm -rf /var/lib/etcd"
echo "  sudo mv /var/lib/etcd.backup.${TIMESTAMP} /var/lib/etcd"
echo "  sudo systemctl start kubelet"

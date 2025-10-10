#!/bin/bash
# Kubernetes Cluster Backup Script
# Backs up etcd, certificates, and all cluster resources

set -euo pipefail

# Use admin kubeconfig
export KUBECONFIG=/etc/kubernetes/admin.conf

# Configuration
# Override by setting environment variable: export BACKUP_ROOT="/your/path"
BACKUP_ROOT="${BACKUP_ROOT:-/mnt/backup/k8s-backups}"
BACKUP_MOUNT_CHECK="${BACKUP_MOUNT_CHECK:-$(dirname "$BACKUP_ROOT")}"
DATE=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${BACKUP_ROOT}/${DATE}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"

# Check if backup drive is mounted (skip check if BACKUP_MOUNT_CHECK is empty)
if [ -n "$BACKUP_MOUNT_CHECK" ] && ! mountpoint -q "$BACKUP_MOUNT_CHECK"; then
    echo "ERROR: Backup drive not mounted at $BACKUP_MOUNT_CHECK"
    echo "Hint: Set BACKUP_MOUNT_CHECK='' to skip this check"
    exit 1
fi

# Create backup directory
mkdir -p "${BACKUP_DIR}"

echo "=== Kubernetes Backup Started: $(date) ==="

# 1. Backup etcd snapshot using kubectl exec
echo "Backing up etcd..."
kubectl exec -n kube-system etcd-master-node -- sh -c \
  "ETCDCTL_API=3 etcdctl snapshot save /var/lib/etcd/snapshot-backup.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key"

# Copy snapshot from host filesystem (etcd container mounts /var/lib/etcd from host)
echo "Copying snapshot to backup location..."
cp /var/lib/etcd/snapshot-backup.db "${BACKUP_DIR}/etcd-snapshot.db"

# Verify the snapshot from host
echo "Verifying snapshot..."
if [ -f "${BACKUP_DIR}/etcd-snapshot.db" ]; then
    SNAPSHOT_SIZE=$(du -h "${BACKUP_DIR}/etcd-snapshot.db" | cut -f1)
    echo "Snapshot created successfully: ${SNAPSHOT_SIZE}"
else
    echo "ERROR: Snapshot file not found!"
    exit 1
fi

# Clean up snapshot from etcd data directory
rm -f /var/lib/etcd/snapshot-backup.db

# 2. Backup Kubernetes PKI certificates
echo "Backing up PKI certificates..."
cp -r /etc/kubernetes/pki "${BACKUP_DIR}/pki-backup"

# 3. Backup kubeadm config
echo "Backing up kubeadm config..."
cp /etc/kubernetes/*.conf "${BACKUP_DIR}/" 2>/dev/null || true

# 4. Backup static pod manifests
echo "Backing up static pod manifests..."
mkdir -p "${BACKUP_DIR}/manifests"
cp /etc/kubernetes/manifests/*.yaml "${BACKUP_DIR}/manifests/" 2>/dev/null || true

# 5. Backup all kubernetes resources
echo "Backing up cluster resources..."
for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    kubectl get all,configmap,secret,ingress,pvc -n $ns -o yaml > \
      "${BACKUP_DIR}/manifests/${ns}-resources.yaml" 2>/dev/null || true
done

# 6. Create backup metadata
cat > "${BACKUP_DIR}/backup-info.txt" << EOFMETA
Backup Date: $(date)
Kubernetes Version: $(kubectl version --short 2>/dev/null || echo "N/A")
Node Count: $(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo "N/A")
Pod Count: $(kubectl get pods -A --no-headers 2>/dev/null | wc -l || echo "N/A")
Hostname: $(hostname)
Backup Location: ${BACKUP_DIR}
Snapshot Size: ${SNAPSHOT_SIZE}
EOFMETA

# 7. Cleanup old backups
echo "Cleaning up backups older than ${RETENTION_DAYS} days..."
find "${BACKUP_ROOT}" -maxdepth 1 -type d -name "20*" -mtime +${RETENTION_DAYS} -exec rm -rf {} \;

# 8. Create a "latest" symlink
rm -f "${BACKUP_ROOT}/latest"
ln -s "${BACKUP_DIR}" "${BACKUP_ROOT}/latest"

echo ""
echo "=== Backup Completed Successfully ==="
echo "Backup location: ${BACKUP_DIR}"
echo "Backup size: $(du -sh ${BACKUP_DIR} | cut -f1)"
echo "Total K8s backups disk usage: $(du -sh ${BACKUP_ROOT} | cut -f1)"
echo "External drive free space: $(df -h "$BACKUP_ROOT" | tail -1 | awk '{print $4}')"

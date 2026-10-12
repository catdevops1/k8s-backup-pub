#!/bin/bash
#
# Kubernetes cluster restore — from R2 or from the local secondary copy
#
# Restores etcd, PKI, kubeconfigs and static pod manifests onto a control-plane
# node. Two situations, both handled:
#
#   in-place  — the node still has a working kubeadm install; this rolls etcd
#               back to a snapshot. Run this script and it does everything.
#
#   rebuild   — fresh host, nothing installed. Run this script with --prepare-only
#               to lay down PKI and etcd data, then run `kubeadm init` yourself.
#               PKI MUST be in place before init, or kubeadm generates a new CA
#               and every existing worker credential becomes invalid.
#
# Configuration: shares /etc/default/backup-k8s with backup-k8s.sh.
#
set -euo pipefail

# ---------------------------------------------------------------- config ----
R2_REMOTE="r2:BUCKET/cluster"
LOCAL_MOUNT="/mnt/backup"
LOCAL_ROOT=""

# shellcheck disable=SC1091
[ -f /etc/default/backup-k8s ] && . /etc/default/backup-k8s
LOCAL_ROOT="${LOCAL_ROOT:-${LOCAL_MOUNT}/k8s-backups}"

MASTER_NAME="${MASTER_NAME:-$(hostname)}"
MASTER_IP="${MASTER_IP:-$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')}"

PREPARE_ONLY=0
SOURCE=""

# ------------------------------------------------------------- utilities ----
log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

usage() {
    cat <<EOF
Usage: $0 [--prepare-only] <backup-directory | R2-timestamp>

  --prepare-only   Restore PKI and etcd data but do not touch kubelet.
                   Use this on a rebuilt host, then run kubeadm init.

Local backups:
EOF
    ls -1dt "${LOCAL_ROOT}"/20* 2>/dev/null | head -10 | sed 's/^/  /' \
        || echo "  (none — is ${LOCAL_MOUNT} mounted?)"
    echo ""
    echo "Off-site backups (R2):"
    rclone lsf --dirs-only "$R2_REMOTE" 2>/dev/null | sort -r | head -10 | sed 's/^/  /' \
        || echo "  (rclone not configured or R2 unreachable)"
    echo ""
    echo "Examples:"
    echo "  $0 ${LOCAL_ROOT}/latest"
    echo "  $0 20260830-000001                 # pulls from R2"
    echo "  $0 --prepare-only 20260830-000001  # rebuild: init afterwards"
    exit 1
}

# ------------------------------------------------------------ arguments -----
while [ $# -gt 0 ]; do
    case "$1" in
        --prepare-only) PREPARE_ONLY=1; shift ;;
        -h|--help)      usage ;;
        *)              SOURCE="$1"; shift ;;
    esac
done
[ -n "$SOURCE" ] || usage

# ------------------------------------------------- resolve the source -------
# A bare timestamp means "fetch it from R2"; anything else is a local path.
if [ -d "$SOURCE" ]; then
    BACKUP_DIR="$SOURCE"
    log "Using local backup: ${BACKUP_DIR}"
else
    command -v rclone >/dev/null || fail "'${SOURCE}' is not a directory and rclone is not installed"
    case "$R2_REMOTE" in
        *BUCKET*) fail "R2_REMOTE is not configured — set it in /etc/default/backup-k8s" ;;
    esac
    BACKUP_DIR="$(mktemp -d /tmp/k8s-restore.XXXXXX)"
    chmod 700 "$BACKUP_DIR"
    trap 'rm -rf "$BACKUP_DIR"' EXIT
    log "Fetching ${R2_REMOTE}/${SOURCE} ..."
    rclone copy "${R2_REMOTE}/${SOURCE}" "$BACKUP_DIR" --stats-one-line \
        || fail "could not fetch ${SOURCE} from R2"
fi

# ------------------------------------------------------ validate source -----
[ -f "${BACKUP_DIR}/etcd-snapshot.db" ] || fail "no etcd-snapshot.db in ${BACKUP_DIR}"

# Integrity first. A corrupted backup discovered mid-restore is worse than one
# discovered before the current etcd data has been moved aside.
if [ -f "${BACKUP_DIR}/SHA256SUMS" ]; then
    log "Verifying checksums..."
    ( cd "$BACKUP_DIR" && sha256sum -c --quiet SHA256SUMS ) \
        || fail "checksum mismatch — this backup is damaged, do not use it"
else
    log "WARNING: no SHA256SUMS in this backup, skipping integrity check"
fi

# Pick the right tool. etcdutl is the supported one for offline operations;
# etcd 3.6 removed `etcdctl snapshot status/restore`, and on a rebuilt host
# neither may be present.
if command -v etcdutl >/dev/null 2>&1; then
    ETCD_RESTORE=(etcdutl snapshot restore)
    ETCD_STATUS=(etcdutl snapshot status)
elif command -v etcdctl >/dev/null 2>&1; then
    export ETCDCTL_API=3
    ETCD_RESTORE=(etcdctl snapshot restore)
    ETCD_STATUS=(etcdctl snapshot status)
else
    fail "neither etcdutl nor etcdctl found — install etcdutl matching your etcd version"
fi

log "Snapshot contents:"
"${ETCD_STATUS[@]}" "${BACKUP_DIR}/etcd-snapshot.db" --write-out=table \
    || fail "snapshot will not parse — refusing to restore from it"

for f in ca.crt ca.key sa.key; do
    [ -f "${BACKUP_DIR}/pki-backup/${f}" ] \
        || fail "backup is missing ${f}; workers would need a full rejoin"
done

# ---------------------------------------------------------- confirmation ----
echo ""
[ -f "${BACKUP_DIR}/backup-info.txt" ] && cat "${BACKUP_DIR}/backup-info.txt"
echo ""
echo "This will REPLACE cluster state on ${MASTER_NAME} (${MASTER_IP})."
if [ "$PREPARE_ONLY" -eq 1 ]; then
    echo "Mode: prepare-only — PKI and etcd data will be laid down, kubelet untouched."
else
    echo "Mode: in-place — kubelet will be stopped, etcd replaced, kubelet restarted."
    echo "Current etcd data will be moved aside, not deleted."
fi
echo ""
read -rp "Type 'yes' to proceed: " confirm
[ "$confirm" = "yes" ] || { echo "Cancelled."; exit 0; }

# ------------------------------------------------------------- restore ------
if [ "$PREPARE_ONLY" -eq 0 ]; then
    log "Stopping kubelet..."
    sudo systemctl stop kubelet
    # Containers outlive the kubelet; give the static pods a moment to exit so
    # etcd is not still writing to the data directory we are about to move.
    sleep 10
fi

TIMESTAMP="$(date +%s)"
if [ -d /var/lib/etcd ]; then
    log "Moving current etcd data to /var/lib/etcd.backup.${TIMESTAMP}"
    sudo mv /var/lib/etcd "/var/lib/etcd.backup.${TIMESTAMP}"
fi

# PKI before anything that might generate certificates. On a rebuild this is
# what makes `kubeadm init` reuse the existing CA instead of minting a new one.
log "Restoring PKI..."
sudo mkdir -p /etc/kubernetes/pki
sudo cp -r "${BACKUP_DIR}/pki-backup/." /etc/kubernetes/pki/

log "Restoring kubeconfigs..."
sudo cp "${BACKUP_DIR}"/*.conf /etc/kubernetes/ 2>/dev/null || \
    log "WARNING: no kubeconfigs in backup"

if [ -d "${BACKUP_DIR}/manifests" ] && [ "$PREPARE_ONLY" -eq 0 ]; then
    log "Restoring static pod manifests..."
    sudo mkdir -p /etc/kubernetes/manifests
    sudo cp "${BACKUP_DIR}/manifests"/*.yaml /etc/kubernetes/manifests/ 2>/dev/null || true
fi

log "Restoring etcd data..."
sudo "${ETCD_RESTORE[@]}" "${BACKUP_DIR}/etcd-snapshot.db" \
    --data-dir=/var/lib/etcd \
    --name="$MASTER_NAME" \
    --initial-cluster="${MASTER_NAME}=https://${MASTER_IP}:2380" \
    --initial-advertise-peer-urls="https://${MASTER_IP}:2380" \
    || fail "etcd restore failed — original data is at /var/lib/etcd.backup.${TIMESTAMP}"

sudo chown -R root:root /var/lib/etcd /etc/kubernetes/pki

# ---------------------------------------------------------------- finish ----
if [ "$PREPARE_ONLY" -eq 1 ]; then
    cat <<EOF

=== Prepared ===

PKI and etcd data are in place. Now initialise the control plane:

  sudo kubeadm init \\
    --apiserver-advertise-address=${MASTER_IP} \\
    --control-plane-endpoint=${MASTER_IP} \\
    --pod-network-cidr=10.244.0.0/16 \\
    --ignore-preflight-errors=DirAvailable--var-lib-etcd

kubeadm will detect the restored CA and reuse it, so existing workers keep their
credentials. Reinstall the CNI afterwards, then check the nodes reconnect.
EOF
    exit 0
fi

log "Starting kubelet..."
sudo systemctl start kubelet

log "Waiting for the API server..."
for i in $(seq 1 60); do
    if kubectl --kubeconfig=/etc/kubernetes/admin.conf get --raw='/readyz' >/dev/null 2>&1; then
        log "API server responding after ${i}0s"
        break
    fi
    [ "$i" -eq 60 ] && log "WARNING: API server not responding after 10 minutes"
    sleep 10
done

export KUBECONFIG=/etc/kubernetes/admin.conf
echo ""
kubectl get nodes 2>/dev/null || echo "Nodes not available yet."
echo ""
kubectl get pods -n kube-system 2>/dev/null | grep -E 'etcd|apiserver|controller|scheduler' \
    || echo "Control plane pods not available yet."

cat <<EOF

=== Restore complete ===

Verify:
  kubectl get nodes
  kubectl get pods -A | grep -v Running
  kubectl get application -n argocd        # ArgoCD will resync from git

Workers may take a few minutes to reconnect. If one does not:
  ssh <worker> 'sudo systemctl restart kubelet'

Longhorn volumes and Vault contents are NOT restored by this script. Databases
must be restored separately from their pg_dump files.

To roll back this restore:
  sudo systemctl stop kubelet
  sudo rm -rf /var/lib/etcd
  sudo mv /var/lib/etcd.backup.${TIMESTAMP} /var/lib/etcd
  sudo systemctl start kubelet
EOF

#!/bin/bash
#
# Kubernetes cluster backup — R2 primary, local secondary
#
# Backs up: etcd snapshot, PKI, kubeconfigs, static pod manifests,
#           and a YAML export of all cluster resources (incl. CRDs).
#
# R2 upload is REQUIRED — the script exits non-zero if it fails.
# Local copy is best-effort and skipped if the mount is missing.
#
# Configuration: override the defaults below in /etc/default/backup-k8s
# (see examples/config.example). Keep real bucket names out of git.
#
set -euo pipefail

# ---------------------------------------------------------------- config ----
export KUBECONFIG=/etc/kubernetes/admin.conf

R2_REMOTE="r2:BUCKET/cluster"
LOCAL_MOUNT="/mnt/backup"
LOCAL_ROOT=""
LOCAL_RETENTION_DAYS=30
ETCD_POD="etcd-$(hostname)"

# shellcheck disable=SC1091
[ -f /etc/default/backup-k8s ] && . /etc/default/backup-k8s
LOCAL_ROOT="${LOCAL_ROOT:-${LOCAL_MOUNT}/k8s-backups}"

DATE="$(date +%Y%m%d-%H%M%S)"
LOCKFILE="/var/lock/backup-k8s.lock"

# Timeouts (seconds) so a wedged disk or dead API server can't hang forever.
T_SNAPSHOT=300
T_KUBECTL=120
T_RCLONE=1800

# ------------------------------------------------------------- utilities ----
log()  { echo "[$(date +%H:%M:%S)] $*"; }
fail() { echo "[$(date +%H:%M:%S)] ERROR: $*" >&2; exit 1; }

case "$R2_REMOTE" in
    *BUCKET*) fail "R2_REMOTE is not configured — set it in /etc/default/backup-k8s" ;;
esac

# Prevent overlapping runs (a slow upload must not collide with the next cron).
exec 9>"$LOCKFILE"
flock -n 9 || fail "another backup is already running"

WORKDIR="$(mktemp -d /tmp/k8s-backup.XXXXXX)"
chmod 700 "$WORKDIR"
# WORKDIR holds ca.key in plaintext — always shred it, even on failure.
trap 'rm -rf "$WORKDIR"' EXIT

log "=== Backup ${DATE} started ==="

# --------------------------------------------------------- 1. etcd snapshot -
# etcd images are distroless since v1.34: call etcdctl directly, no `sh -c`.
log "Taking etcd snapshot..."
timeout "$T_SNAPSHOT" kubectl exec -n kube-system "$ETCD_POD" -- etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/kubernetes/pki/etcd/ca.crt \
    --cert=/etc/kubernetes/pki/etcd/server.crt \
    --key=/etc/kubernetes/pki/etcd/server.key \
    snapshot save "/var/lib/etcd/snapshot-${DATE}.db" \
    || fail "etcd snapshot failed"

# The etcd container mounts /var/lib/etcd from the host, so the file is here.
cp "/var/lib/etcd/snapshot-${DATE}.db" "${WORKDIR}/etcd-snapshot.db"
rm -f "/var/lib/etcd/snapshot-${DATE}.db"

# -------------------------------------------------------- 2. verify it -----
# A snapshot that can't be read is not a backup. Check before uploading.
log "Verifying snapshot..."
if command -v etcdutl >/dev/null 2>&1; then
    VERIFY="etcdutl snapshot status"
elif command -v etcdctl >/dev/null 2>&1; then
    VERIFY="etcdctl snapshot status"
else
    VERIFY=""
fi

if [ -n "$VERIFY" ]; then
    $VERIFY "${WORKDIR}/etcd-snapshot.db" --write-out=table \
        || fail "snapshot failed verification — refusing to upload"
else
    log "WARNING: no etcdutl/etcdctl on host, falling back to size check"
    SIZE_BYTES=$(stat -c%s "${WORKDIR}/etcd-snapshot.db")
    [ "$SIZE_BYTES" -gt 1048576 ] || fail "snapshot is only ${SIZE_BYTES} bytes"
fi

# ------------------------------------------- 3. PKI, kubeconfigs, manifests -
# Without ca.key + sa.key a restore cannot reuse the original CA, which means
# every worker needs `kubeadm reset` and rejoin. These are the critical files.
log "Copying PKI and kubeconfigs..."
cp -r /etc/kubernetes/pki "${WORKDIR}/pki-backup"
cp /etc/kubernetes/*.conf "${WORKDIR}/" 2>/dev/null || true

for f in ca.crt ca.key sa.key; do
    [ -f "${WORKDIR}/pki-backup/${f}" ] || fail "missing critical file: ${f}"
done

log "Copying static pod manifests..."
mkdir -p "${WORKDIR}/manifests"
cp /etc/kubernetes/manifests/*.yaml "${WORKDIR}/manifests/" 2>/dev/null || true

# ----------------------------------------------- 4. resource YAML export ----
# Belt-and-braces on top of etcd: lets you restore a single namespace without
# a full etcd rollback. Includes CRDs (ArgoCD Apps, ExternalSecrets, HTTPRoutes,
# Longhorn volumes) which a plain `kubectl get all` would silently skip.
log "Exporting cluster resources..."
mkdir -p "${WORKDIR}/resources"

NS_KINDS=$(timeout "$T_KUBECTL" kubectl api-resources \
    --verbs=list --namespaced=true -o name 2>/dev/null \
    | grep -v 'events' | tr '\n' ',' | sed 's/,$//')

for ns in $(timeout "$T_KUBECTL" kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
    timeout "$T_KUBECTL" kubectl get "$NS_KINDS" -n "$ns" -o yaml \
        > "${WORKDIR}/resources/ns-${ns}.yaml" 2>/dev/null || true
done

CLUSTER_KINDS=$(timeout "$T_KUBECTL" kubectl api-resources \
    --verbs=list --namespaced=false -o name 2>/dev/null \
    | tr '\n' ',' | sed 's/,$//')
timeout "$T_KUBECTL" kubectl get "$CLUSTER_KINDS" -o yaml \
    > "${WORKDIR}/resources/cluster-scoped.yaml" 2>/dev/null || true

# --------------------------------------------------- 5. metadata + hashes ---
# /version reports the API server; `kubectl version` would report the client.
cat > "${WORKDIR}/backup-info.txt" <<EOF
Backup Date:  $(date -Is)
Hostname:     $(hostname)
K8s Version:  $(kubectl get --raw /version 2>/dev/null | grep -m1 '"gitVersion"' | cut -d'"' -f4)
Node Count:   $(kubectl get nodes --no-headers 2>/dev/null | wc -l)
Pod Count:    $(kubectl get pods -A --no-headers 2>/dev/null | wc -l)
Snapshot:     $(du -h "${WORKDIR}/etcd-snapshot.db" | cut -f1)
EOF

# Lets a future restore prove the files weren't corrupted in transit or on disk.
( cd "$WORKDIR" && find . -type f ! -name SHA256SUMS -exec sha256sum {} + > SHA256SUMS )

# ----------------------------------------------------- 6. upload to R2 ------
# This is the copy that survives the control plane and the local drive both dying.
log "Uploading to ${R2_REMOTE}/${DATE} ..."
timeout "$T_RCLONE" rclone copy "$WORKDIR" "${R2_REMOTE}/${DATE}" \
    --checksum --transfers=4 --stats-one-line \
    || fail "R2 upload failed — no off-site copy of this backup exists"

REMOTE_COUNT=$(rclone ls "${R2_REMOTE}/${DATE}" | wc -l)
LOCAL_COUNT=$(find "$WORKDIR" -type f | wc -l)
[ "$REMOTE_COUNT" -eq "$LOCAL_COUNT" ] \
    || fail "R2 has ${REMOTE_COUNT} files, expected ${LOCAL_COUNT}"
log "R2 upload verified: ${REMOTE_COUNT} files"

# ------------------------------------------------ 7. local copy (optional) --
# Faster to restore from, but not required — R2 already has it.
if mountpoint -q "$LOCAL_MOUNT"; then
    log "Copying to ${LOCAL_ROOT}/${DATE} ..."
    if mkdir -p "${LOCAL_ROOT}/${DATE}" && cp -r "${WORKDIR}"/* "${LOCAL_ROOT}/${DATE}/"; then
        ln -sfn "${LOCAL_ROOT}/${DATE}" "${LOCAL_ROOT}/latest"
        find "$LOCAL_ROOT" -maxdepth 1 -type d -name '20*' \
            -mtime "+${LOCAL_RETENTION_DAYS}" -exec rm -rf {} + 2>/dev/null || true
        log "Local copy complete ($(df -h "$LOCAL_MOUNT" | tail -1 | awk '{print $4}') free)"
    else
        log "WARNING: local copy failed — R2 copy is intact, continuing"
    fi
else
    log "WARNING: ${LOCAL_MOUNT} not mounted — skipping local copy"
fi

log "=== Backup ${DATE} completed successfully ==="

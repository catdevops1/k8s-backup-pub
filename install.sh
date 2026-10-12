#!/bin/bash
#
# Install backup-k8s.sh and restore-k8s.sh on a kubeadm control-plane node.
#
set -euo pipefail

CONFIG=/etc/default/backup-k8s
cd "$(dirname "$0")"

[ "$EUID" -eq 0 ] || { echo "Run as root (sudo ./install.sh)"; exit 1; }

echo "Checking requirements..."
missing=0
for cmd in kubectl rclone flock timeout sha256sum; do
    if command -v "$cmd" >/dev/null 2>&1; then
        echo "  ok       $cmd"
    else
        echo "  MISSING  $cmd"; missing=1
    fi
done
if command -v etcdutl >/dev/null 2>&1; then
    echo "  ok       etcdutl"
else
    echo "  WARNING  etcdutl not found — snapshots will only be size-checked."
    echo "           Install the etcdutl matching your cluster's etcd version."
fi
[ "$missing" -eq 0 ] || { echo "Install the missing tools and re-run."; exit 1; }

# rclone < 1.61 (e.g. the Ubuntu 24.04 package) returns 501 NotImplemented on R2.
RCLONE_VER=$(rclone version 2>/dev/null | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
if [ -n "$RCLONE_VER" ] && [ "$(printf '%s\n1.61\n' "$RCLONE_VER" | sort -V | head -1)" != "1.61" ]; then
    echo "  WARNING  rclone ${RCLONE_VER} is older than 1.61 and has known R2 upload issues."
fi

echo ""
echo "Installing scripts to /usr/local/bin ..."
install -m 755 backup-k8s.sh  /usr/local/bin/backup-k8s.sh
install -m 755 restore-k8s.sh /usr/local/bin/restore-k8s.sh

if [ -f "$CONFIG" ]; then
    echo "Keeping existing ${CONFIG}"
else
    install -m 600 examples/config.example "$CONFIG"
    echo "Created ${CONFIG} from the example — edit R2_REMOTE before the first run."
fi

cat <<EOF

Done. Next steps:

  1. Configure:      sudo \$EDITOR ${CONFIG}
  2. Test a backup:  sudo backup-k8s.sh
  3. Schedule it:    sudo crontab -e   (see examples/crontab.example)
  4. List backups:   sudo restore-k8s.sh

See README.md for the restore procedure.
EOF

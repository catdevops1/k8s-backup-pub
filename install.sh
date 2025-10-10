#!/bin/bash
set -e

echo "🚀 Installing Kubernetes Backup Scripts..."
echo ""

# Check if running as root
if [ "$EUID" -ne 0 ]; then 
    echo "❌ Please run as root (use sudo)"
    exit 1
fi

# Copy scripts
echo "📝 Copying scripts to /usr/local/bin/..."
cp backup-k8s.sh /usr/local/bin/
cp restore-k8s.sh /usr/local/bin/

# Make executable
chmod +x /usr/local/bin/backup-k8s.sh
chmod +x /usr/local/bin/restore-k8s.sh

echo ""
echo "✅ Installation complete!"
echo ""
echo "📋 Next steps:"
echo "  1. Configure backup location (optional):"
echo "     export BACKUP_ROOT='/your/backup/path'"
echo "     Or edit: sudo vim /usr/local/bin/backup-k8s.sh"
echo ""
echo "  2. Test backup:"
echo "     sudo backup-k8s.sh"
echo ""
echo "  3. Set up automated backups:"
echo "     sudo crontab -e"
echo "     Add: 0 */12 * * * /usr/local/bin/backup-k8s.sh >> /var/log/k8s-backup.log 2>&1"
echo ""
echo "  4. Test restore (list backups):"
echo "     sudo restore-k8s.sh"
echo ""
echo "📖 See README.md for full documentation"

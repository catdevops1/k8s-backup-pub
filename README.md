# Kubernetes Bare Metal Backup Solution

Automated backup and restore scripts for Kubernetes clusters running on bare metal with etcd as a static pod.

## 🎯 Features

- 🔄 **Automated etcd snapshots** via `kubectl exec`
- 📦 **Complete cluster state backup** (all resources)
- 🔐 **PKI certificates backup**
- 📋 **Static pod manifests backup**
- ⏰ **Cron-based scheduling**
- 💾 **External storage support**
- 🔧 **Easy one-command restore**
- 🗑️ **Automatic cleanup** (configurable retention)

## 📦 What Gets Backed Up

- ✅ **etcd snapshot** - Complete cluster state database
- ✅ **PKI certificates** - All TLS certificates and keys
- ✅ **Kubeconfig files** - admin.conf, controller-manager.conf, scheduler.conf
- ✅ **Static pod manifests** - etcd, kube-apiserver, kube-controller-manager, kube-scheduler
- ✅ **All cluster resources** - Deployments, Services, ConfigMaps, Secrets, PVCs, Ingresses, etc.
- ✅ **Backup metadata** - Timestamp, cluster version, node/pod counts

## ⚡ Quick Start

### Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/k8s-backup.git
cd k8s-backup

# Run installer
chmod +x install.sh
sudo ./install.sh
```

Or manually:

```bash
sudo cp backup-k8s.sh /usr/local/bin/
sudo cp restore-k8s.sh /usr/local/bin/
sudo chmod +x /usr/local/bin/backup-k8s.sh
sudo chmod +x /usr/local/bin/restore-k8s.sh
```

### First Backup

```bash
# Run manual backup to test
sudo backup-k8s.sh
```

Expected output:
```
=== Kubernetes Backup Started: ... ===
Backing up etcd...
Snapshot created successfully: 13M
Backing up PKI certificates...
Backing up kubeadm config...
...
=== Backup Completed Successfully ===
Backup location: /mnt/backup/k8s-backups/20241010-132533
Backup size: 15M
```

### Automated Backups

Set up cron for automatic backups:

```bash
sudo crontab -e
```

Add one of these lines:

```bash
# Every 12 hours (recommended)
0 */12 * * * /usr/local/bin/backup-k8s.sh >> /var/log/k8s-backup.log 2>&1

# Daily at 2 AM
0 2 * * * /usr/local/bin/backup-k8s.sh >> /var/log/k8s-backup.log 2>&1

# Every 6 hours
0 */6 * * * /usr/local/bin/backup-k8s.sh >> /var/log/k8s-backup.log 2>&1
```

## ⚙️ Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `BACKUP_ROOT` | `/mnt/backup/k8s-backups` | Where to store backups |
| `BACKUP_MOUNT_CHECK` | Parent of `BACKUP_ROOT` | Path to check if mounted (set to empty to skip) |
| `RETENTION_DAYS` | `30` | How many days to keep backups |
| `MASTER_NODE_NAME` | `master-node` | Master node hostname (for restore) |
| `MASTER_NODE_IP` | `192.168.4.100` | Master node IP (for restore) |

### Configuration Methods

**Method 1: Environment Variables**
```bash
export BACKUP_ROOT="/your/backup/path"
sudo -E backup-k8s.sh
```

**Method 2: Edit Scripts**
```bash
sudo vim /usr/local/bin/backup-k8s.sh
# Change the default values at the top
```

**Method 3: Cron Environment**
```bash
sudo crontab -e
# Add at top:
BACKUP_ROOT="/your/backup/path"
0 */12 * * * /usr/local/bin/backup-k8s.sh >> /var/log/k8s-backup.log 2>&1
```

See `examples/config.example` for more options.

## 🔧 Recovery / Restore

### List Available Backups

```bash
sudo restore-k8s.sh
```

### Restore from Latest Backup

```bash
sudo restore-k8s.sh /mnt/backup/k8s-backups/latest
```

### Restore from Specific Backup

```bash
sudo restore-k8s.sh /mnt/backup/k8s-backups/20241010-132533
```

### What Happens During Restore

1. ⚠️ Stops kubelet (cluster goes down)
2. 💾 Backs up current etcd data (safety measure)
3. 📥 Restores etcd snapshot
4. 🔐 Restores PKI certificates (if in backup)
5. ✅ Starts kubelet
6. ⏳ Waits 30 seconds for cluster to stabilize
7. 📊 Shows cluster status

## 📊 Monitoring

```bash
# View backup logs
tail -f /var/log/k8s-backup.log

# List all backups
ls -lht /mnt/backup/k8s-backups/

# Check backup sizes
du -sh /mnt/backup/k8s-backups/*

# View latest backup info
cat /mnt/backup/k8s-backups/latest/backup-info.txt
```

## 🔍 Disaster Recovery Scenarios

### Scenario 1: Corrupted etcd
```bash
# Symptoms: Cluster won't start, etcd pod crashing
sudo restore-k8s.sh /mnt/backup/k8s-backups/latest
```

### Scenario 2: Accidental Deletion
```bash
# Deleted a namespace? Restore just that resource:
kubectl apply -f /mnt/backup/k8s-backups/latest/manifests/namespace-resources.yaml
```

### Scenario 3: Disk Failure
```bash
# 1. Replace disk, reinstall OS
# 2. Reinstall Kubernetes
# 3. Initialize cluster with same settings
# 4. Restore from backup
sudo restore-k8s.sh /mnt/backup/k8s-backups/latest
```

## 📋 Requirements

- Kubernetes cluster (v1.28+)
- etcd running as a static pod
- `kubectl` configured with admin access
- Root access on master node
- External storage for backups (USB drive, NFS, etc.)

## 🏗️ How It Works

### Backup Process

1. Uses `kubectl exec` to run `etcdctl` inside the etcd container
2. Saves snapshot to `/var/lib/etcd/snapshot-backup.db` (mounted from host)
3. Copies snapshot from host filesystem to backup location
4. Backs up certificates from `/etc/kubernetes/pki/`
5. Exports all cluster resources to YAML manifests
6. Creates metadata file with backup info
7. Cleans up old backups (30-day retention by default)
8. Creates `latest` symlink for convenience

### Why `kubectl exec`?

The etcd container is minimal and doesn't include `tar` or `cat`, so we:
1. Save snapshot inside the container to a host-mounted path
2. Access it directly from the host filesystem
3. This works because `/var/lib/etcd` is mounted from the host

## 🔒 Security Notes

- Backups contain **sensitive data** (secrets, certificates, tokens)
- Store backups on encrypted drives
- Limit access to backup location (root only)
- Never commit actual backups to git repositories
- Consider encrypting backup archives for offsite storage

## 🧪 Testing Your Backups

**Always test your backup/restore process!**

```bash
# 1. Note current state
kubectl get pods -A > /tmp/before.txt

# 2. Create test resource
kubectl create deployment test-backup --image=nginx

# 3. Take backup
sudo backup-k8s.sh

# 4. Delete the test resource
kubectl delete deployment test-backup

# 5. Restore from backup
sudo restore-k8s.sh /mnt/backup/k8s-backups/latest

# 6. Verify test resource is back
kubectl get deployment test-backup  # Should exist again!
```

## 📁 Backup Structure

```
/mnt/backup/k8s-backups/
├── 20241010-132533/
│   ├── etcd-snapshot.db              # 13 MB - etcd database
│   ├── pki-backup/                   # TLS certificates
│   ├── admin.conf                    # Kubeconfig files
│   ├── controller-manager.conf
│   ├── scheduler.conf
│   ├── manifests/
│   │   ├── etcd.yaml                 # Static pod manifests
│   │   ├── kube-apiserver.yaml
│   │   ├── default-resources.yaml    # All resources per namespace
│   │   ├── kube-system-resources.yaml
│   │   └── ...
│   └── backup-info.txt               # Metadata
├── 20241010-000000/
├── 20241009-120000/
└── latest -> 20241010-132533/        # Symlink to latest
```

## 🤝 Contributing

Contributions welcome! Please:
1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

## 📄 License

MIT License - See LICENSE file

## ⚠️ Disclaimer

This tool is provided as-is. Always test your backup and restore procedures in a non-production environment first. The authors are not responsible for data loss.

---

**Made with ❤️ for the Kubernetes community**

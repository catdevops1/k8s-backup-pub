# Kubernetes Cluster Backup & Disaster Recovery

Backup and restore tooling for a five-node bare-metal Kubernetes cluster running
production workloads. Backups go off-site to Cloudflare R2 first, with a secondary
copy on network-attached storage.

The design assumption is that the control-plane node is the most likely thing to
fail — so the off-site copy is mandatory and the local copy is a convenience, not
the safety net. Storage is deliberately attached to a *worker* node rather than
the control plane, so a failing disk cannot take the API server down with it.

---

## What gets backed up

| Component | Contents | Recoverable from |
|---|---|---|
| etcd snapshot | Every API object in the cluster | `etcdutl snapshot restore` |
| PKI | Cluster CA, service-account keys, component certs | Direct copy into `/etc/kubernetes/pki` |
| kubeconfigs | `admin.conf`, `kubelet.conf`, `controller-manager.conf`, `scheduler.conf`, `super-admin.conf` | Direct copy |
| Static pod manifests | Control-plane component definitions | Direct copy |
| Resource YAML export | Per-namespace and cluster-scoped objects, including CRDs | `kubectl apply` for selective restore |
| `SHA256SUMS` | Integrity manifest for every file above | `sha256sum -c` |
| Vault storage | Tarball of the Vault file backend + checksum (separate schedule) | Untar into the Vault PV; unseals via KMS |
| PostgreSQL dumps | Per-application `pg_dump` output + checksum (separate schedule) | `psql` restore |

**The PKI matters as much as the snapshot.** Without the original `ca.key` and
`sa.key`, a restored control plane issues a new certificate authority, every
worker's kubelet credentials become invalid, and each node needs `kubeadm reset`
and a full rejoin. With them, workers reconnect on their own.

### Coverage gaps

- **Longhorn volume data.** etcd holds the Longhorn CRDs describing each volume;
  the replica data lives on worker disks. Restoring etcd onto rebuilt workers
  gives you volume definitions pointing at data that no longer exists.
  Application data is protected separately by the database and Vault jobs.
- **Vault depends on the KMS key.** The nightly tarball is ciphertext under
  Vault's barrier key. AWS KMS auto-unseal decrypts it only while the KMS key and
  the IAM credentials that use it still exist. Lose those and the backup is
  unreadable.
- **Container images.** Pulled fresh on restore; anything built locally and never
  pushed to a registry will not return.

---

## Storage topology

```
control plane                          worker node
├── backup-k8s.sh (root cron)          ├── USB 3.0 ── 2TB external drive
├── /etc/kubernetes/pki   (local)      └── /srv/backup  (NFS export)
└── /mnt/backup ─────── NFS ───────────────────┘
                └────── rclone ──────► Cloudflare R2
```

The backup script runs on the control plane because it needs local access to
`/etc/kubernetes/pki` and the etcd static pod. Only the *destination* is remote.

### Why the drive is not on the control plane

It used to be, on a bus-powered USB 2.0 hub shared with a keyboard and mouse. A
2.5" spinning drive can draw more current at spin-up than that arrangement
supplies, and the drive began failing to reach operating speed:

```
sd 2:0:0:0: [sda] Spinning up disk...
..............................not responding...
sd 2:0:0:0: [sda] tag#19 timing out command, waited 180s
I/O error, dev sda, sector 3 op 0x0:(READ)
```

The consequences were not confined to the backup. Processes blocked on that
device entered uninterruptible sleep, which included `modprobe`. With module
loading wedged, `iptable_nat` never autoloaded, `kube-proxy` created empty NAT
chains, and every ClusterIP became unreachable — `metrics-server`, the MetalLB
speaker and the monitoring agent all crashlooped with `dial tcp 10.96.0.1:443:
i/o timeout`. A failing peripheral took out cluster networking.

Moved to a direct USB 3.0 port on a worker, the same drive enumerates in about a
second and has been stable since.

**Takeaway:** storage that the control plane depends on should not share a power
budget with peripherals, and ideally should not be attached to the control plane
at all.

### NFS server (worker node)

```bash
sudo apt install -y nfs-kernel-server
sudo mkdir -p /srv/backup
```

`/etc/fstab` — `nofail` so a missing drive never blocks boot:

```
UUID=<DRIVE_UUID> /srv/backup ext4 defaults,nofail 0 2
```

`/etc/exports`:

```
/srv/backup <LAN_SUBNET>/24(rw,sync,no_subtree_check,no_root_squash)
```

`no_root_squash` is required because the backup runs as root and writes
root-owned files. It means any root user on the subnet can write as root to this
export — acceptable on an isolated network with the subnet restriction, but it is
a real trade-off worth stating rather than glossing over.

```bash
sudo exportfs -ra
sudo systemctl enable --now nfs-kernel-server
```

### NFS client (control plane)

```
<NFS_SERVER_IP>:/srv/backup /mnt/backup nfs _netdev,nofail,soft,timeo=50,retrans=2 0 0
```

**`soft` is not optional.** With the default `hard`, if the NFS server goes away
mid-write, processes block in uninterruptible sleep indefinitely — the same D-state
failure that caused the outage described above, just relocated. `soft` makes I/O
return an error instead.

Verify the entry before relying on it at boot:

```bash
sudo umount /mnt/backup && sudo mount -a && df -h /mnt/backup
```

---

## Requirements

- Kubernetes provisioned with `kubeadm`, etcd 3.6 (verified on v1.36.5)
- `rclone` **≥ 1.61** — earlier versions (including the Ubuntu 24.04 package,
  1.60.1) fail every R2 object upload with `501 NotImplemented`, succeeding only
  on internal retry and filling the log with errors on every successful run:
  ```bash
  curl https://rclone.org/install.sh | sudo bash
  sudo apt-mark hold rclone     # stop apt reinstating the old package
  ```
- `etcdutl` on the host, matching the cluster's etcd version, for snapshot
  verification and restore. etcd 3.6 removed `etcdctl snapshot status/restore`,
  and the etcd binaries live *inside* the static pod, so a rebuilt host will not
  have them until installed:
  ```bash
  ETCD_VER=3.6.8
  curl -sL https://github.com/etcd-io/etcd/releases/download/v${ETCD_VER}/etcd-v${ETCD_VER}-linux-amd64.tar.gz | tar xz -C /tmp
  sudo install /tmp/etcd-v${ETCD_VER}-linux-amd64/etcdutl /usr/local/bin/
  ```
- An R2 bucket and an S3-compatible API token scoped to it

---

## Installation

```bash
git clone https://github.com/catdevops1/k8s-backup-pub.git
cd k8s-backup-pub
sudo ./install.sh
sudo $EDITOR /etc/default/backup-k8s
sudo backup-k8s.sh
```

`install.sh` checks dependencies, installs both scripts to `/usr/local/bin`, and
creates `/etc/default/backup-k8s` from `examples/config.example` if it does not
exist. An existing config file is never overwritten.

---

## Configuration

### Script settings

Both scripts read `/etc/default/backup-k8s` (mode `600`). Real bucket names and
paths live there, never in the scripts, so the same file that runs in production
is the one in this repository:

```bash
R2_REMOTE="r2:<BUCKET>/cluster"
LOCAL_MOUNT="/mnt/backup"
LOCAL_ROOT="/mnt/backup/k8s-backups"
LOCAL_RETENTION_DAYS=30
```

`backup-k8s.sh` refuses to run until `R2_REMOTE` is set. See
[`examples/config.example`](examples/config.example) for every option.

### R2 credentials

R2 credentials live in `/root/.config/rclone/rclone.conf` (mode `600`), because
the backup runs from the root crontab:

```ini
[r2]
type = s3
provider = Cloudflare
access_key_id = <ACCESS_KEY_ID>
secret_access_key = <SECRET_ACCESS_KEY>
endpoint = https://<ACCOUNT_ID>.r2.cloudflarestorage.com
region = auto
```

These are deliberately **not** stored in Vault. In the scenario where you need the
backups, Vault may be part of what is down — a credential you can only retrieve
from a healthy cluster is useless for restoring a broken one.

```bash
sudo rclone lsd r2:<BUCKET>       # verify
```

### Layout and retention

```
r2:<BUCKET>/
├── cluster/YYYYMMDD-HHMMSS/    etcd + PKI + manifests + resource export
├── vault/                      Vault file-backend tarballs + .sha256
└── db/<app>/                   PostgreSQL dumps + .sha256
```

Retention is enforced by R2 lifecycle rules rather than by the script, so nothing
has to reach out and delete remote objects:

| Prefix | Retention |
|---|---|
| `cluster/` | 30 days |
| `db/` | 60 days |
| `vault/` | set per your recovery window |
| local NFS | 30 days |

Database dumps are kept longer off-site than the cluster snapshots, since they
are small and are the only copy of application data. Cluster retention is capped
at 30 days to stay within the R2 free tier at roughly 168 MB per daily snapshot.

Lifecycle rules must specify the prefix. A rule with no prefix applies to the
whole bucket, and where rules overlap the shortest retention wins — so an
unprefixed 30-day rule silently overrides a 60-day rule on `db/`.

---

## Schedules

All jobs run from the **root** crontab, staggered so they never compete for the
same storage:

```cron
# Cluster backup (this repo)
0  1 * * * /usr/local/bin/backup-k8s.sh     >> /var/log/k8s-backup.log 2>&1

# Vault file backend (lives on Longhorn, not in etcd)
30 1 * * * /usr/local/bin/backup-vault.sh   >> /var/log/vault-backup.log 2>&1

# Per-application database dumps
0  2 * * * /usr/local/bin/backup-db-<app1>.sh >> /var/log/db-backup-<app1>.log 2>&1
10 2 * * * /usr/local/bin/backup-db-<app2>.sh >> /var/log/db-backup-<app2>.log 2>&1
```

`flock` in the cluster script prevents overlapping runs.

---

## Behaviour

The cluster, Vault and database scripts fail loudly and early:

- `set -euo pipefail` throughout
- **Mount guard.** `/mnt/backup` is an ordinary directory when nothing is mounted
  there. Without an explicit `mountpoint -q` check, a dump writes to the local
  root filesystem and reports success — this is how a backup failure goes
  unnoticed for weeks. The cluster script downgrades this to a warning, since R2
  already has the data.
- **Verification before trust.** The etcd snapshot is checked with
  `etcdutl snapshot status` before upload; a snapshot that will not parse is never
  shipped. `ca.crt`, `ca.key` and `sa.key` are asserted present.
- **`.part` staging.** Database dumps are written to a temporary name and only
  renamed once `pg_dump` emits its completion marker, so a truncated dump never
  occupies the final filename.
- **R2 failure is fatal.** A run that produced no off-site copy is not a
  successful run. Uploaded file count is compared against local file count.
- **Timeouts.** Every external call is wrapped in `timeout`, so failing hardware
  cannot hang the job indefinitely.
- **Cleanup on failure.** The working directory is `mktemp` mode 700 with a `trap`,
  since it holds the cluster CA private key in plaintext while the job runs.

A healthy run, roughly 55 seconds:

```
[00:00:01] === Backup 20260830-000001 started ===
[00:00:01] Taking etcd snapshot...
[00:00:02] Verifying snapshot...
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| e36ed15f | 90242011 |       4327 |      84 MB |
+----------+----------+------------+------------+
[00:00:02] Copying PKI and kubeconfigs...
[00:00:02] Copying static pod manifests...
[00:00:02] Exporting cluster resources...
[00:00:16] Uploading to r2:<BUCKET>/cluster/20260830-000001 ...
[00:00:26] R2 upload verified: 53 files
[00:00:26] Copying to /mnt/backup/k8s-backups/20260830-000001 ...
[00:00:55] Local copy complete (1.7T free)
[00:00:55] === Backup 20260830-000001 completed successfully ===
```

### Verifying a backup, not just listing it

A folder in the bucket proves nothing. Before every cluster upgrade, each layer is
checked by hand:

```bash
# etcd: checksum, opens cleanly, key count close to live etcd
grep etcd-snapshot.db SHA256SUMS | sha256sum -c -
etcdutl snapshot status etcd-snapshot.db -w table
sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  get / --prefix --keys-only | grep -c .

# Vault: checksum and KV data present
sha256sum -c vault-data-<date>.tgz.sha256
tar tzf vault-data-<date>.tgz | grep -c '^data/logical/'

# PostgreSQL: dump ran to completion
rclone cat r2:<BUCKET>/db/<app>/<dump>.sql | tail -3
```

Newer `pg_dump` releases end the file with `\unrestrict <token>` instead of the
old "dump complete" comment — seeing it means the dump finished. Restore with a
`psql` at least as new as the `pg_dump` that wrote it.

---

## Disaster recovery

### Restore ordering

**Place the PKI before running `kubeadm init`, not after.**

`kubeadm init` generates a fresh CA and then signs every kubeconfig against it.
Restoring the old PKI afterwards invalidates all of them and nothing
authenticates. When `ca.crt` and `ca.key` already exist, kubeadm detects and
reuses them instead of generating new ones.

### Scenario 1 — control-plane host lost, backups available

New host, **same hostname and IP** as the original: worker `kubelet.conf` files
and the API server certificate SANs both reference it.

```bash
# 1. Matching Kubernetes version — a downgrade will not start against a
#    newer etcd snapshot. Check backup-info.txt for the version.
sudo apt install -y kubelet=1.36.5-* kubeadm=1.36.5-* kubectl=1.36.5-*
sudo apt-mark hold kubelet kubeadm kubectl
# plus etcdutl — see Requirements

# 2. Retrieve and verify
sudo rclone copy r2:<BUCKET>/cluster/<TIMESTAMP> /restore
cd /restore && sha256sum -c SHA256SUMS

# 3. PKI and kubeconfigs FIRST
sudo mkdir -p /etc/kubernetes/pki
sudo cp -r /restore/pki-backup/* /etc/kubernetes/pki/
sudo cp /restore/*.conf /etc/kubernetes/

# 4. etcd data
sudo etcdutl snapshot restore /restore/etcd-snapshot.db \
  --data-dir=/var/lib/etcd \
  --name=<MASTER_HOSTNAME> \
  --initial-cluster=<MASTER_HOSTNAME>=https://<MASTER_IP>:2380 \
  --initial-advertise-peer-urls=https://<MASTER_IP>:2380
sudo chown -R root:root /var/lib/etcd

# 5. Initialise against the restored state
sudo kubeadm init \
  --apiserver-advertise-address=<MASTER_IP> \
  --control-plane-endpoint=<MASTER_IP> \
  --pod-network-cidr=10.244.0.0/16 \
  --ignore-preflight-errors=DirAvailable--var-lib-etcd
```

Steps 2–4 are what `restore-k8s.sh --prepare-only <TIMESTAMP>` automates.
Workers reconnect on their own; `sudo systemctl restart kubelet` on each if not.

### Scenario 2 — worker node failure

etcd lives on the control plane, so no cluster state is at risk. Reboot and wait.
If the node needs to rejoin:

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d /var/lib/cni
sudo kubeadm join <MASTER_IP>:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

If the node hosting the NFS export is the one that failed, `/mnt/backup` on the
control plane returns I/O errors rather than hanging — that is what `soft` buys —
and the cluster backup continues to R2 with a warning.

### Scenario 3 — selective restore

```bash
sudo rclone copy r2:<BUCKET>/cluster/<TIMESTAMP>/resources /restore/resources
kubectl apply -f /restore/resources/ns-<namespace>.yaml
```

For GitOps-managed workloads it is usually cleaner to let ArgoCD resync from git
than to reapply an export.

### Scenario 4 — database restore

Pull the dump, check its `.sha256`, then restore with:

```bash
psql -v ON_ERROR_STOP=1 ... < <app>_YYYYMMDD_HHMMSS.sql
```

`ON_ERROR_STOP=1` is essential. Without it psql continues past failures and exits
0, leaving a half-restored database that reports success.

### Scenario 5 — total loss

Rebuild the control plane per Scenario 1, then `kubeadm reset` and rejoin every
worker. Application manifests return from git via ArgoCD, database contents from
the `db/` dumps, and Vault from the `vault/` tarball — provided the KMS key used
for auto-unseal still exists. Longhorn volumes are recreated empty.

---

## Required kernel modules

`kube-proxy` cannot program NAT rules without `iptable_nat`. Linux normally
autoloads it on demand, but if module loading is blocked — a wedged block device
holding `modprobe` in uninterruptible sleep will do it — kube-proxy creates empty
chains, every ClusterIP becomes unreachable, and anything talking to `10.96.0.1`
fails with `i/o timeout`. The symptom looks like a networking fault; the cause is
storage.

```bash
# /etc/modules-load.d/k8s-modules.conf
iptable_nat
iptable_filter
br_netfilter
overlay
```

With the matching sysctls in `/etc/sysctl.d/k8s.conf`:

```
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
```

Diagnostic: an existing but empty `KUBE-SERVICES` chain with `(0 references)`
means kube-proxy started and could not program rules, not that it failed to run.

```bash
sudo iptables -t nat -L KUBE-SERVICES -n | wc -l   # dozens when healthy
curl -k --max-time 5 https://10.96.0.1:443/healthz  # "ok" when healthy
```

---

## Operations

```bash
# Manual run
sudo /usr/local/bin/backup-k8s.sh

# Off-site inventory and size
rclone lsd r2:<BUCKET>/cluster
rclone size r2:<BUCKET>/cluster

# Verify a snapshot without restoring
rclone copy r2:<BUCKET>/cluster/<TIMESTAMP>/etcd-snapshot.db /tmp/
etcdutl snapshot status /tmp/etcd-snapshot.db --write-out=table

# Local copies
ls -lht /mnt/backup/k8s-backups/ | head
tail -f /var/log/k8s-backup.log
```

---

## Security

- Backups contain **every Kubernetes Secret and the cluster CA private key** in
  plaintext. Treat the bucket, the NFS export and the physical drive as equivalent
  in sensitivity to root access on the control plane.
- The R2 API token is scoped to a single bucket with object read/write only.
- Neither the NFS export nor the R2 objects are encrypted at rest. `rclone crypt`
  in front of the R2 remote is the obvious hardening step; retrofitting it means
  re-uploading everything.
- `no_root_squash` on the NFS export grants root-equivalent write access to any
  root user on the subnet.
- The temporary working directory is mode `700` and removed on exit including on
  failure.

---

## Known gaps

- [ ] No alerting on backup failure; silent failure is invisible until someone
      reads the log
- [ ] Resource export suppresses per-namespace errors, so a partial export can
      look complete
- [ ] Vault and database backup scripts are not yet in this repository
- [ ] Vault raft snapshots once the file → raft storage migration is done
- [ ] Restore procedure has not been exercised end to end against fresh hardware
- [ ] Backups are unencrypted at rest

---

## Repository layout

```
backup-k8s.sh               Backup: snapshot, verify, upload, secondary copy
restore-k8s.sh              Restore: PKI placement, etcd restore, cluster init
install.sh                  Dependency check, install to /usr/local/bin, config
examples/config.example     Template for /etc/default/backup-k8s
examples/crontab.example    Root crontab entries
README.md                   This file
```

---

**Last verified:** 12 October 2026 against Kubernetes v1.36.5 and etcd 3.6.8.
Backup contents were checked by checksum, `etcdutl snapshot status` and a live
key-count comparison before the v1.35 → v1.36 upgrade.

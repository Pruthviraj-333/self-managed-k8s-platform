#!/bin/bash
# =============================================================================
# backup-etcd.sh: Take Automated Snapshot of Etcd Database
# Run ONLY on Control Plane (k8s-cp1)
# =============================================================================
set -euo pipefail

BACKUP_DIR="/var/lib/etcd-backup"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
SNAPSHOT_PATH="${BACKUP_DIR}/etcd-snapshot-${TIMESTAMP}.db"

sudo mkdir -p "$BACKUP_DIR"

echo "Taking etcd snapshot to $SNAPSHOT_PATH..."
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save "$SNAPSHOT_PATH"

echo "Verifying snapshot status:"
sudo ETCDCTL_API=3 etcdctl --write-out=table snapshot status "$SNAPSHOT_PATH"

# Create symlink to latest
sudo ln -sf "$SNAPSHOT_PATH" "${BACKUP_DIR}/latest-snapshot.db"
echo ">>> Etcd backup completed successfully! Symlinked to ${BACKUP_DIR}/latest-snapshot.db"

#!/bin/bash
# =============================================================================
# restore-etcd.sh: Perform Point-In-Time Restore from Etcd Snapshot
# Run ONLY on Control Plane (k8s-cp1)
# =============================================================================
set -euo pipefail

SNAPSHOT_FILE="${1:-/var/lib/etcd-backup/latest-snapshot.db}"
RESTORE_DIR="/var/lib/etcd-restored-$(date +%s)"

if [ ! -f "$SNAPSHOT_FILE" ]; then
  echo "Error: Snapshot file $SNAPSHOT_FILE does not exist!"
  exit 1
fi

echo ">>> [1/4] Temporarily stopping control plane static pods..."
sudo mkdir -p /tmp/k8s-manifests-temp
sudo mv /etc/kubernetes/manifests/*.yaml /tmp/k8s-manifests-temp/
sleep 8

echo ">>> [2/4] Restoring snapshot to new data directory: $RESTORE_DIR..."
sudo ETCDCTL_API=3 etcdctl snapshot restore "$SNAPSHOT_FILE" \
  --data-dir="$RESTORE_DIR"

echo ">>> [3/4] Updating etcd static pod manifest hostPath..."
sudo sed -i "s|path: /var/lib/etcd.*|path: ${RESTORE_DIR}|g" /tmp/k8s-manifests-temp/etcd.yaml

echo ">>> [4/4] Restarting control plane static pods..."
sudo mv /tmp/k8s-manifests-temp/*.yaml /etc/kubernetes/manifests/

echo "Waiting for kube-apiserver to recover..."
for i in {1..30}; do
  if kubectl get nodes &>/dev/null; then
    echo ">>> Cluster API Server is back online!"
    kubectl get nodes
    exit 0
  fi
  echo "Waiting for API server... ($i/30)"
  sleep 3
done

echo "Error: API server did not recover within 90s."
exit 1

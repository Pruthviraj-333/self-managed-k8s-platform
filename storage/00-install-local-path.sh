#!/bin/bash
# =============================================================================
# 00-install-local-path.sh: Deploy Self-Managed Local Path Storage Provisioner
# =============================================================================
set -euo pipefail

echo "=========================================================="
echo ">>> [1/3] Applying Local Path Provisioner Manifests"
echo "=========================================================="
# Rancher Local Path Provisioner dynamically provisions PersistentVolumes (PVs)
# using hostPath on each worker node's local disk (/opt/local-path-provisioner).
# This perfectly emulates on-prem direct-attached storage (DAS) or local NVMe drives
# without invoking cloud APIs (AWS EBS CSI driver).
kubectl apply -f "$(dirname "$0")/local-path-storage.yaml"

echo "Waiting for local-path-provisioner pod to be Ready..."
kubectl wait --namespace local-path-storage \
  --for=condition=ready pod \
  --selector=app=local-path-provisioner \
  --timeout=120s

echo "=========================================================="
echo ">>> [2/3] Setting local-path as Default StorageClass"
echo "=========================================================="
kubectl patch storageclass local-path -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'

echo "=========================================================="
echo ">>> [3/3] Inspecting StorageClasses"
echo "=========================================================="
kubectl get storageclass
echo ">>> Local Path storage provisioner is ready for dynamic PV provisioning!"

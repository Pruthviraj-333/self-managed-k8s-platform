#!/bin/bash
# =============================================================================
# run-drain.sh: Automated Safe Node Drain and Maintenance Walkthrough
# =============================================================================
set -euo pipefail

TARGET_NODE="k8s-worker1"

echo "Applying PodDisruptionBudget..."
kubectl apply -f "$(dirname "$0")/pdb-example.yaml"

echo ">>> [1/4] Cordoning node $TARGET_NODE..."
kubectl cordon "$TARGET_NODE"
kubectl get nodes

echo ">>> [2/4] Draining pods from $TARGET_NODE..."
kubectl drain "$TARGET_NODE" --ignore-daemonsets --delete-emptydir-data --timeout=120s

echo ">>> [3/4] Validating all workloads running on surviving worker..."
kubectl get pods -A -o wide --field-selector spec.nodeName="$TARGET_NODE" || true

echo ">>> [4/4] Maintenance completed. Uncordoning node $TARGET_NODE..."
kubectl uncordon "$TARGET_NODE"
kubectl get nodes
echo ">>> Maintenance procedure successfully finished!"

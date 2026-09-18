#!/bin/bash
# =============================================================================
# run-test.sh: Real-Time Timer & State Watcher for Node Eviction
# =============================================================================
set -euo pipefail

TARGET_NODE="k8s-worker2"
echo "Monitoring node: $TARGET_NODE and pod rescheduling..."

START_TIME=$(date +%s)

while true; do
  CURRENT_TIME=$(date +%s)
  ELAPSED=$((CURRENT_TIME - START_TIME))
  
  NODE_STATUS=$(kubectl get node "$TARGET_NODE" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "Unknown")
  echo "-------------------------------------------------------------"
  echo "[T+${ELAPSED}s] Node $TARGET_NODE Ready Condition: $NODE_STATUS"
  
  # Check if any pods are terminating or rescheduling
  kubectl get pods -n boutique -o wide | grep -E "(Terminating|ContainerCreating|Pending|$TARGET_NODE)" || true
  
  sleep 10
done

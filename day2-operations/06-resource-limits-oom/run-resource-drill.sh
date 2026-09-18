#!/bin/bash
# =============================================================================
# run-resource-drill.sh: Execute OOMKill and CPU Throttling Verification
# =============================================================================
set -euo pipefail

echo ">>> [1/3] Deploying Memory Leaker Pod (oom-demo-pod)..."
kubectl apply -f "$(dirname "$0")/resource-pods.yaml"

echo "Streaming logs until kernel OOMKill occurs..."
kubectl logs -f oom-demo-pod || true

echo ">>> [2/3] Inspecting Termination Reason and Exit Code..."
kubectl describe pod oom-demo-pod | grep -A 5 "Last State:" || kubectl describe pod oom-demo-pod | grep -A 5 "State:"

echo ">>> [3/3] Inspecting CPU Throttled Pod..."
kubectl get pod cpu-throttle-pod

echo "Cleaning up resource test pods..."
kubectl delete pod oom-demo-pod cpu-throttle-pod --force --grace-period=0 || true
echo ">>> Resource limits drill completed!"

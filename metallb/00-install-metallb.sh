#!/bin/bash
# =============================================================================
# 00-install-metallb.sh: Install MetalLB Bare-Metal Load Balancer
# =============================================================================
set -euo pipefail

METALLB_VERSION="v0.14.5"

echo "=========================================================="
echo ">>> [1/3] Deploying MetalLB Controller and Speaker DaemonSet"
echo "=========================================================="
# On bare-metal, MetalLB provides network load-balancer implementation
# without needing AWS Network Load Balancer (NLB) or Classic ELB.
kubectl apply -f "https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml"

echo "Waiting for MetalLB controller and speaker pods to be Ready..."
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=120s

echo "=========================================================="
echo ">>> [2/3] Applying IPAddressPool and L2Advertisement"
echo "=========================================================="
kubectl apply -f "$(dirname "$0")/01-ipaddresspool.yaml"
kubectl apply -f "$(dirname "$0")/02-l2advertisement.yaml"

echo "=========================================================="
echo ">>> [3/3] Verifying MetalLB Configuration"
echo "=========================================================="
kubectl get ipaddresspools.metallb.io -n metallb-system
kubectl get l2advertisements.metallb.io -n metallb-system
kubectl get pods -n metallb-system -o wide

echo ">>> MetalLB successfully deployed and listening for LoadBalancer services!"

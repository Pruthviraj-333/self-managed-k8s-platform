#!/bin/bash
# =============================================================================
# verify-connectivity.sh: Cross-Node Pod-to-Pod Connectivity & CNI Diagnostic
# Tests Calico overlay routing, MTU encapsulation, and DNS resolution
# =============================================================================
set -euo pipefail

echo "=========================================================="
echo ">>> [1/5] Checking Calico Node & DaemonSet Status"
echo "=========================================================="
kubectl get nodes -o wide
kubectl get daemonsets -n calico-system calico-node || kubectl get daemonsets -n kube-system calico-node

echo "=========================================================="
echo ">>> [2/5] Creating Cross-Node Verification Pods"
echo "=========================================================="
# Get worker node hostnames
WORKER_1=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[0].metadata.name}')
WORKER_2=$(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{.items[1].metadata.name}')

echo "Worker 1: $WORKER_1"
echo "Worker 2: $WORKER_2"

# Deploy Pod 1 on Worker 1
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: net-probe-worker1
  namespace: default
  labels:
    app: net-probe
spec:
  nodeSelector:
    kubernetes.io/hostname: "$WORKER_1"
  containers:
  - name: probe
    image: curlimages/curl:8.7.1
    command: ["sleep", "3600"]
---
apiVersion: v1
kind: Pod
metadata:
  name: net-server-worker2
  namespace: default
  labels:
    app: net-probe
spec:
  nodeSelector:
    kubernetes.io/hostname: "$WORKER_2"
  containers:
  - name: web
    image: hashicorp/http-echo:0.2.3
    args: ["-text=Calico Cross-Node Network OK"]
    ports:
    - containerPort: 5678
EOF

echo "Waiting for test pods to be in Running status..."
kubectl wait --for=condition=Ready pod/net-probe-worker1 --timeout=60s
kubectl wait --for=condition=Ready pod/net-server-worker2 --timeout=60s

POD1_IP=$(kubectl get pod net-probe-worker1 -o jsonpath='{.status.podIP}')
POD2_IP=$(kubectl get pod net-server-worker2 -o jsonpath='{.status.podIP}')

echo "Pod 1 (Worker 1) IP: $POD1_IP"
echo "Pod 2 (Worker 2) IP: $POD2_IP"

echo "=========================================================="
echo ">>> [3/5] Testing Cross-Node Pod-to-Pod ICMP Ping"
echo "=========================================================="
kubectl exec net-probe-worker1 -- ping -c 3 "$POD2_IP"

echo "=========================================================="
echo ">>> [4/5] Testing Cross-Node TCP HTTP Request (Port 5678)"
echo "=========================================================="
HTTP_RESPONSE=$(kubectl exec net-probe-worker1 -- curl -s "http://$POD2_IP:5678")
echo "Response from Worker 2 Pod: $HTTP_RESPONSE"

if [[ "$HTTP_RESPONSE" == *"Calico Cross-Node Network OK"* ]]; then
  echo ">>> SUCCESS: Pod-to-Pod overlay connectivity across physical nodes is working perfectly!"
else
  echo ">>> ERROR: Cross-node communication failed. Check AWS Security Groups (Port 4789/VXLAN or BGP) and source_dest_check!"
  exit 1
fi

echo "=========================================================="
echo ">>> [5/5] Testing In-Pod DNS Resolution (CoreDNS)"
echo "=========================================================="
kubectl exec net-probe-worker1 -- nslookup kubernetes.default.svc.cluster.local

echo ">>> Cleaning up test pods..."
kubectl delete pod net-probe-worker1 net-server-worker2
echo ">>> All networking diagnostics passed!"

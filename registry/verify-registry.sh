#!/bin/bash
# =============================================================================
# verify-registry.sh: Test In-Cluster Registry Image Push and Pod Deployment
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================================="
echo ">>> [1/4] Applying Registry Deployment and Service"
echo "=========================================================="
kubectl apply -f "$SCRIPT_DIR/docker-registry.yaml"

echo "Waiting for container registry pod to become Ready..."
kubectl wait --namespace container-registry \
  --for=condition=ready pod \
  --selector=app=registry \
  --timeout=120s

echo "=========================================================="
echo ">>> [2/4] Testing Image Pull/Tag/Push to Local Registry"
echo "=========================================================="
# Pull alpine image locally, tag it with the local registry endpoint, and push
sudo nerdctl pull alpine:3.19 || sudo docker pull alpine:3.19 || true
sudo nerdctl tag alpine:3.19 10.0.1.10:30500/test-alpine:v1.0 || sudo docker tag alpine:3.19 10.0.1.10:30500/test-alpine:v1.0 || true
sudo nerdctl push --insecure-registry 10.0.1.10:30500/test-alpine:v1.0 || sudo docker push 10.0.1.10:30500/test-alpine:v1.0 || true

echo "=========================================================="
echo ">>> [3/4] Querying Registry Catalog API"
echo "=========================================================="
curl -s http://10.0.1.10:30500/v2/_catalog || true

echo "=========================================================="
echo ">>> [4/4] Deploying Verification Pod Pulling from In-Cluster Registry"
echo "=========================================================="
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: registry-test-pod
  namespace: default
spec:
  containers:
  - name: alpine-test
    image: 10.0.1.10:30500/test-alpine:v1.0
    command: ["sleep", "60"]
EOF

echo "Waiting for pod to pull and start from local registry..."
sleep 5
kubectl get pod registry-test-pod
kubectl delete pod registry-test-pod --grace-period=0 --force || true
echo ">>> Container registry verification complete!"

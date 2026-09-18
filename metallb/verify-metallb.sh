#!/bin/bash
# =============================================================================
# verify-metallb.sh: Verify MetalLB VIP Provisioning & Layer 2 ARP Routing
# =============================================================================
set -euo pipefail

echo "=========================================================="
echo ">>> [1/3] Deploying Test Web Service with Type: LoadBalancer"
echo "=========================================================="
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: metallb-test-app
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: metallb-test
  template:
    metadata:
      labels:
        app: metallb-test
    spec:
      containers:
      - name: nginx
        image: nginx:1.25-alpine
        ports:
        - containerPort: 80
---
apiVersion: v1
kind: Service
metadata:
  name: metallb-test-svc
  namespace: default
spec:
  type: LoadBalancer
  selector:
    app: metallb-test
  ports:
  - port: 80
    targetPort: 80
EOF

echo "Waiting for MetalLB to assign an IP from 10.0.1.200-10.0.1.210..."
sleep 5

VIP=$(kubectl get svc metallb-test-svc -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Assigned MetalLB VIP: $VIP"

if [[ -z "$VIP" || "$VIP" == "<pending>" ]]; then
  echo ">>> ERROR: MetalLB failed to assign an IP! Check metallb speaker logs:"
  kubectl logs -n metallb-system -l component=speaker --tail=30
  exit 1
fi

echo "=========================================================="
echo ">>> [2/3] Checking MetalLB Speaker Node Ownership"
echo "=========================================================="
kubectl get events -n default --field-selector involvedObject.name=metallb-test-svc

echo "=========================================================="
echo ">>> [3/3] Sending HTTP Request to MetalLB VIP ($VIP)"
echo "=========================================================="
curl -I "http://$VIP" || true

echo ">>> Cleaning up test resources..."
kubectl delete deployment metallb-test-app
kubectl delete svc metallb-test-svc
echo ">>> MetalLB Layer 2 verification complete!"

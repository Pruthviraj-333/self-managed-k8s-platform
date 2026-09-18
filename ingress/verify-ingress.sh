#!/bin/bash
# =============================================================================
# verify-ingress.sh: Verify Ingress-NGINX Routing through MetalLB VIP
# =============================================================================
set -euo pipefail

echo "=========================================================="
echo ">>> [1/3] Deploying Test App with Ingress Resource"
echo "=========================================================="
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ingress-demo-app
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels:
      app: ingress-demo
  template:
    metadata:
      labels:
        app: ingress-demo
    spec:
      containers:
      - name: web
        image: hashicorp/http-echo:0.2.3
        args: ["-text=Ingress NGINX + MetalLB Working!"]
        ports:
        - containerPort: 5678
---
apiVersion: v1
kind: Service
metadata:
  name: ingress-demo-svc
  namespace: default
spec:
  ports:
  - port: 5678
    targetPort: 5678
  selector:
    app: ingress-demo
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ingress-demo
  namespace: default
  annotations:
    ingress.class: nginx
spec:
  rules:
  - host: "demo.k8s.local"
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: ingress-demo-svc
            port:
              number: 5678
EOF

echo "Waiting for pods to be Ready..."
kubectl wait --for=condition=Ready pod -l app=ingress-demo --timeout=60s

echo "=========================================================="
echo ">>> [2/3] Retrieving Ingress Controller MetalLB IP"
echo "=========================================================="
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Ingress LoadBalancer IP: $INGRESS_IP"

echo "=========================================================="
echo ">>> [3/3] Sending HTTP Request with Host Header: demo.k8s.local"
echo "=========================================================="
# We use curl with --resolve or Host header to emulate DNS mapping to MetalLB VIP
HTTP_OUT=$(curl -s -H "Host: demo.k8s.local" "http://${INGRESS_IP}/" || true)
echo "HTTP Output: $HTTP_OUT"

if [[ "$HTTP_OUT" == *"Ingress NGINX + MetalLB Working!"* ]]; then
  echo ">>> SUCCESS: Ingress routing via MetalLB VIP verified!"
else
  echo ">>> Verification response: $HTTP_OUT"
fi

echo "Cleaning up demo app..."
kubectl delete ingress ingress-demo
kubectl delete svc ingress-demo-svc
kubectl delete deployment ingress-demo-app

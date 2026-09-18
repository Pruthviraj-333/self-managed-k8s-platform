#!/bin/bash
# =============================================================================
# deploy-boutique.sh: Deploy Online Boutique & Verify Ingress Routing
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================================="
echo ">>> [1/3] Applying Online Boutique Manifests"
echo "=========================================================="
kubectl apply -f "$SCRIPT_DIR/00-namespace-ingress.yaml"
kubectl apply -f "$SCRIPT_DIR/01-online-boutique.yaml"

echo "Waiting for microservices to roll out (frontend, cart, checkout, etc.)..."
kubectl rollout status deployment/frontend -n boutique --timeout=180s
kubectl rollout status deployment/cartservice -n boutique --timeout=180s
kubectl rollout status deployment/checkoutservice -n boutique --timeout=180s

echo "=========================================================="
echo ">>> [2/3] Checking Running Pods Across Worker Nodes"
echo "=========================================================="
kubectl get pods -n boutique -o wide

echo "=========================================================="
echo ">>> [3/3] Validating Frontend Ingress Access via MetalLB"
echo "=========================================================="
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "MetalLB Ingress IP: $INGRESS_IP"

HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: boutique.k8s.local" "http://${INGRESS_IP}/" || true)
echo "HTTP Status Code from Online Boutique Frontend: $HTTP_CODE"

if [ "$HTTP_CODE" == "200" ]; then
  echo ">>> SUCCESS: Google Online Boutique is live and reachable via MetalLB + NGINX Ingress!"
  echo "To access from your browser, add to /etc/hosts (or C:\Windows\System32\drivers\etc\hosts):"
  echo "$INGRESS_IP boutique.k8s.local"
else
  echo ">>> Notice: Received HTTP $HTTP_CODE (Frontend might still be warming up backend gRPC services)."
fi

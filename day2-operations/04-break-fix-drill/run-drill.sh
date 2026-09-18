#!/bin/bash
# =============================================================================
# run-drill.sh: Automated Break-Fix Diagnostic Execution
# =============================================================================
set -euo pipefail

echo ">>> [1/4] Injecting Network Failure (Applying Bad NetworkPolicy)..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-catalog
  namespace: boutique
spec:
  podSelector:
    matchLabels:
      app: productcatalogservice
  policyTypes:
  - Ingress
  ingress: []
EOF

echo "Testing frontend error response..."
sleep 3
INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: boutique.k8s.local" "http://${INGRESS_IP}/" || true)
echo "HTTP Status during outage: $HTTP_STATUS"

echo ">>> [2/4] Inspecting Error Logs from Frontend..."
kubectl logs -n boutique deployment/frontend --tail=5 || true

echo ">>> [3/4] Applying Remediated NetworkPolicy..."
cat <<EOF | kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: isolate-catalog
  namespace: boutique
spec:
  podSelector:
    matchLabels:
      app: productcatalogservice
  policyTypes:
  - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    ports:
    - protocol: TCP
      port: 3550
EOF

sleep 3
echo ">>> [4/4] Verifying Fix..."
HTTP_STATUS_FIXED=$(curl -s -o /dev/null -w "%{http_code}" -H "Host: boutique.k8s.local" "http://${INGRESS_IP}/" || true)
echo "HTTP Status after remediation: $HTTP_STATUS_FIXED"

if [ "$HTTP_STATUS_FIXED" == "200" ]; then
  echo ">>> SUCCESS: Incident resolved and verified!"
fi

# Cleanup
kubectl delete networkpolicy isolate-catalog -n boutique

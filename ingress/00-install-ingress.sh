#!/bin/bash
# =============================================================================
# 00-install-ingress.sh: Install Ingress-NGINX Controller with MetalLB Integration
# =============================================================================
set -euo pipefail

INGRESS_NGINX_VERSION="v1.10.1"

echo "=========================================================="
echo ">>> [1/3] Deploying Ingress-NGINX Bare-Metal Controller"
echo "=========================================================="
# Ingress-NGINX bare-metal deployment creates an IngressClass and controller Deployment
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-${INGRESS_NGINX_VERSION}/deploy/static/provider/baremetal/deploy.yaml"

echo "Waiting for Ingress-NGINX Controller deployment to roll out..."
kubectl wait --namespace ingress-nginx \
  --for=condition=ready pod \
  --selector=app.kubernetes.io/component=controller \
  --timeout=180s

echo "=========================================================="
echo ">>> [2/3] Exposing Ingress-NGINX via MetalLB LoadBalancer"
echo "=========================================================="
# By default, bare-metal provider manifest creates a NodePort service.
# We patch it to type: LoadBalancer so MetalLB binds a dedicated VPC VIP to it.
kubectl patch svc ingress-nginx-controller -n ingress-nginx -p '{"spec": {"type": "LoadBalancer"}}'

sleep 5

echo "=========================================================="
echo ">>> [3/3] Inspecting Assigned Ingress LoadBalancer IP"
echo "=========================================================="
kubectl get svc ingress-nginx-controller -n ingress-nginx -o wide

INGRESS_IP=$(kubectl get svc ingress-nginx-controller -n ingress-nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo ">>> Ingress-NGINX Controller successfully bound to MetalLB VIP: $INGRESS_IP"
echo "You can now point DNS or local /etc/hosts entries to $INGRESS_IP!"

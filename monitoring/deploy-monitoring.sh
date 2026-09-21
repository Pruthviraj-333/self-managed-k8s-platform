#!/bin/bash
# =============================================================================
# deploy-monitoring.sh: Deploy Prometheus, Alertmanager, Node-Exporter, Grafana
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================================="
echo ">>> [1/4] Applying Monitoring Stack Manifests"
echo "=========================================================="
kubectl apply -f "$SCRIPT_DIR/01-node-exporter.yaml"
kubectl apply -f "$SCRIPT_DIR/02-prometheus-alert-rules.yaml"
kubectl apply -f "$SCRIPT_DIR/03-prometheus-deploy.yaml"
kubectl apply -f "$SCRIPT_DIR/04-alertmanager.yaml"
kubectl apply -f "$SCRIPT_DIR/05-grafana.yaml"

echo "Waiting for monitoring pods to roll out..."
kubectl rollout status daemonset/node-exporter -n monitoring --timeout=120s
kubectl rollout status deployment/prometheus -n monitoring --timeout=180s
kubectl rollout status deployment/alertmanager -n monitoring --timeout=120s
kubectl rollout status deployment/grafana -n monitoring --timeout=120s

echo "=========================================================="
echo ">>> [2/4] Verifying Monitoring Services & Targets"
echo "=========================================================="
kubectl get pods,svc -n monitoring -o wide

echo "=========================================================="
echo ">>> [3/4] Querying Prometheus Scrape Targets via Port-Forward"
echo "=========================================================="
kubectl get endpoints -n monitoring

echo "=========================================================="
echo ">>> [4/4] Access Information"
echo "=========================================================="
echo "Prometheus API: http://10.0.1.10:9090 (or port-forward: kubectl port-forward -n monitoring svc/prometheus 9090:9090)"
echo "Alertmanager:   http://10.0.1.10:9093 (or port-forward: kubectl port-forward -n monitoring svc/alertmanager 9093:9093)"
echo "Grafana UI:     http://<CONTROL_PLANE_PUBLIC_IP>:32000 (User/Pass: see Vault at secret/grafana/credentials)"

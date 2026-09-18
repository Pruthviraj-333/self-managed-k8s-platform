#!/bin/bash
# =============================================================================
# run-rollout-drill.sh: Automated Rolling Upgrade and Instant Rollback Drill
# =============================================================================
set -euo pipefail

echo ">>> [1/4] Injecting Bad Image Tag into Frontend Deployment..."
kubectl set image deployment/frontend server=gcr.io/google-samples/microservices-demo/frontend:v99.9.9 -n boutique --record

echo "Observing stalling rollout (waiting 15s)..."
sleep 15
kubectl get pods -n boutique -l app=frontend

echo ">>> [2/4] Checking Rollout History..."
kubectl rollout history deployment/frontend -n boutique

echo ">>> [3/4] Triggering Instant Rollback..."
kubectl rollout undo deployment/frontend -n boutique

echo "Waiting for rollback to complete..."
kubectl rollout status deployment/frontend -n boutique --timeout=60s

echo ">>> [4/4] Rollback Successful! Verified healthy pods:"
kubectl get pods -n boutique -l app=frontend

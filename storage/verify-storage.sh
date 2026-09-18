#!/bin/bash
# =============================================================================
# verify-storage.sh: Test Dynamic PV Provisioning, State Persistence, and Pod Crash
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=========================================================="
echo ">>> [1/5] Deploying PostgreSQL StatefulSet with Local Storage"
echo "=========================================================="
kubectl apply -f "$SCRIPT_DIR/postgres-statefulset/postgres-secret-svc.yaml"
kubectl apply -f "$SCRIPT_DIR/postgres-statefulset/postgres-statefulset.yaml"

echo "Waiting for PostgreSQL pod postgres-0 to become Ready..."
kubectl wait --for=condition=Ready pod/postgres-0 --timeout=120s

echo "=========================================================="
echo ">>> [2/5] Inspecting Bound PVC and PersistentVolume"
echo "=========================================================="
kubectl get pvc postgres-data-postgres-0
kubectl get pv

echo "=========================================================="
echo ">>> [3/5] Writing Test Data into PostgreSQL"
echo "=========================================================="
kubectl exec -i postgres-0 -- psql -U postgres_admin -d ecommerce_db <<EOF
CREATE TABLE IF NOT EXISTS cluster_verification (
  id SERIAL PRIMARY KEY,
  test_key VARCHAR(50),
  inserted_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO cluster_verification (test_key) VALUES ('StoragePersistenceVerified');
SELECT * FROM cluster_verification;
EOF

echo "=========================================================="
echo ">>> [4/5] Simulating Pod Crash (Killing postgres-0)"
echo "=========================================================="
NODE_NAME=$(kubectl get pod postgres-0 -o jsonpath='{.spec.nodeName}')
echo "PostgreSQL was scheduled on node: $NODE_NAME"

kubectl delete pod postgres-0
echo "Waiting for StatefulSet controller to recreate postgres-0..."
kubectl wait --for=condition=Ready pod/postgres-0 --timeout=120s

echo "=========================================================="
echo ">>> [5/5] Querying PostgreSQL to Verify Data Persisted"
echo "=========================================================="
PERSISTED_ROW=$(kubectl exec -i postgres-0 -- psql -U postgres_admin -d ecommerce_db -c "SELECT test_key FROM cluster_verification WHERE test_key='StoragePersistenceVerified';" -t | xargs)

if [ "$PERSISTED_ROW" == "StoragePersistenceVerified" ]; then
  echo ">>> SUCCESS: Persistent data survived pod termination!"
  echo ">>> Local Path Provisioner has successfully stored database files on $NODE_NAME in /opt/local-path-provisioner/"
else
  echo ">>> ERROR: Data did not persist across pod restarts!"
  exit 1
fi

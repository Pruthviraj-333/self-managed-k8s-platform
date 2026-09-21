#!/usr/bin/env bash
# =============================================================================
# 01-configure-k8s-auth.sh
# Step 2: Configure Vault's Kubernetes Auth Backend + Policies
#
# This allows pods inside the cluster to authenticate to Vault using their
# ServiceAccount token — no hardcoded tokens needed anywhere.
#
# Run from: k8s-cp1 (control plane node)
# Prerequisite: source storage/vault/.vault-env
# =============================================================================
set -euo pipefail

VAULT_NAMESPACE="vault"

echo "======================================================"
echo " Vault Kubernetes Auth - Configuration"
echo "======================================================"

# Verify environment variables are set
if [[ -z "${VAULT_TOKEN:-}" || -z "${VAULT_ADDR:-}" ]]; then
  echo "ERROR: VAULT_TOKEN and VAULT_ADDR must be set."
  echo "Run: source storage/vault/.vault-env"
  exit 1
fi

# ------------------------------------------------------------------------------
# 1. Enable the Kubernetes auth method
#    This lets pods use their ServiceAccount JWT tokens to authenticate to Vault
# ------------------------------------------------------------------------------
echo "[1/5] Enabling Kubernetes auth method in Vault..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  env VAULT_TOKEN="$VAULT_TOKEN" VAULT_ADDR="$VAULT_ADDR" \
  vault auth enable kubernetes 2>/dev/null || echo "      (already enabled)"
echo "      Done."

# ------------------------------------------------------------------------------
# 2. Configure the Kubernetes auth method
#    Vault needs to know how to verify pod ServiceAccount tokens
# ------------------------------------------------------------------------------
echo "[2/5] Configuring Kubernetes auth with cluster API endpoint..."
K8S_HOST="https://$(kubectl get svc kubernetes -o jsonpath='{.spec.clusterIP}'):443"

kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  env VAULT_TOKEN="$VAULT_TOKEN" \
  vault write auth/kubernetes/config \
    kubernetes_host="$K8S_HOST"
echo "      Kubernetes host configured: $K8S_HOST"

# ------------------------------------------------------------------------------
# 3. Create Vault policies (least-privilege — each app only reads its own secret)
#    Company practice: never give a single policy access to ALL secrets
# ------------------------------------------------------------------------------
echo "[3/5] Creating least-privilege Vault policies..."

# Policy: postgres-app (read-only access to postgres secrets)
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  env VAULT_TOKEN="$VAULT_TOKEN" \
  vault policy write postgres-app - <<'EOF'
# Allow the postgres pod to READ its credentials only
path "secret/data/postgres/credentials" {
  capabilities = ["read"]
}
EOF
echo "      Policy created: postgres-app"

# Policy: grafana-app (read-only access to grafana secrets)
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  env VAULT_TOKEN="$VAULT_TOKEN" \
  vault policy write grafana-app - <<'EOF'
# Allow the grafana pod to READ its credentials only
path "secret/data/grafana/credentials" {
  capabilities = ["read"]
}
EOF
echo "      Policy created: grafana-app"

# Policy: registry-app (read-only access to registry secrets)
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  env VAULT_TOKEN="$VAULT_TOKEN" \
  vault policy write registry-app - <<'EOF'
# Allow registry-related pods to READ registry credentials only
path "secret/data/registry/credentials" {
  capabilities = ["read"]
}
EOF
echo "      Policy created: registry-app"

# Policy: external-secrets-operator (reads ALL secrets — needed by ESO controller)
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  env VAULT_TOKEN="$VAULT_TOKEN" \
  vault policy write external-secrets-operator - <<'EOF'
# External Secrets Operator service account — reads all platform secrets
# to create K8s Secret objects. Scoped to 'secret/' path only.
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["list", "read"]
}
EOF
echo "      Policy created: external-secrets-operator"

# ------------------------------------------------------------------------------
# 4. Create Kubernetes auth roles
#    Each role binds: a ServiceAccount + namespace → a Vault policy
# ------------------------------------------------------------------------------
echo "[4/5] Creating Kubernetes auth roles (ServiceAccount binding)..."

# Role for External Secrets Operator (runs in external-secrets namespace)
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  env VAULT_TOKEN="$VAULT_TOKEN" \
  vault write auth/kubernetes/role/external-secrets-operator \
    bound_service_account_names="external-secrets" \
    bound_service_account_namespaces="external-secrets" \
    policies="external-secrets-operator" \
    ttl=1h
echo "      Role created: external-secrets-operator"

# Role for postgres pod (uses default ServiceAccount in default namespace)
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  env VAULT_TOKEN="$VAULT_TOKEN" \
  vault write auth/kubernetes/role/postgres-role \
    bound_service_account_names="default" \
    bound_service_account_namespaces="default" \
    policies="postgres-app" \
    ttl=1h
echo "      Role created: postgres-role"

# Role for grafana pod (uses default ServiceAccount in monitoring namespace)
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  env VAULT_TOKEN="$VAULT_TOKEN" \
  vault write auth/kubernetes/role/grafana-role \
    bound_service_account_names="default" \
    bound_service_account_namespaces="monitoring" \
    policies="grafana-app" \
    ttl=1h
echo "      Role created: grafana-role"

# ------------------------------------------------------------------------------
# 5. Install External Secrets Operator (ESO) via Helm
#    ESO reads from Vault and auto-creates K8s Secrets for each application
# ------------------------------------------------------------------------------
echo "[5/5] Installing External Secrets Operator (ESO) via Helm..."
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets \
  --create-namespace \
  --set installCRDs=true \
  --wait --timeout 3m
echo "      ESO installed in namespace: external-secrets"

# Create a K8s Secret inside ESO namespace containing the Vault token
# ESO uses this to authenticate to Vault
kubectl create secret generic vault-token \
  --from-literal=token="$VAULT_TOKEN" \
  -n external-secrets \
  --dry-run=client -o yaml | kubectl apply -f -
echo "      Vault token secret created for ESO."

echo ""
echo "======================================================"
echo " Kubernetes Auth Configuration Complete!"
echo " Next step: kubectl apply -f storage/vault/"
echo " (Apply: secret-store.yaml then all *-external-secret.yaml)"
echo "======================================================"

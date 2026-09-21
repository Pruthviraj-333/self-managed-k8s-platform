#!/usr/bin/env bash
# =============================================================================
# 00-install-vault.sh
# Step 1: Deploy HashiCorp Vault on the self-managed Kubernetes cluster
#         using Helm + the existing local-path storage provisioner.
#
# Run from: k8s-cp1 (control plane node)
# =============================================================================
set -euo pipefail

VAULT_NAMESPACE="vault"
VAULT_RELEASE="vault"
VAULT_ADDR="http://127.0.0.1:8200"

echo "======================================================"
echo " HashiCorp Vault - Install & Initialize"
echo "======================================================"

# ------------------------------------------------------------------------------
# 1. Add the HashiCorp Helm repo
# ------------------------------------------------------------------------------
echo "[1/7] Adding HashiCorp Helm repository..."
helm repo add hashicorp https://helm.releases.hashicorp.com
helm repo update
echo "      Done."

# ------------------------------------------------------------------------------
# 2. Deploy Vault via Helm (namespace: vault)
# ------------------------------------------------------------------------------
echo "[2/7] Installing Vault via Helm (namespace: $VAULT_NAMESPACE)..."
helm install "$VAULT_RELEASE" hashicorp/vault \
  --namespace "$VAULT_NAMESPACE" \
  --create-namespace \
  --values "$(dirname "$0")/vault-values.yaml" \
  --wait --timeout 3m
echo "      Done."

# ------------------------------------------------------------------------------
# 3. Wait for the Vault pod to be Running (but it will show 0/1 READY — 
#    this is expected because Vault is sealed and needs initialization)
# ------------------------------------------------------------------------------
echo "[3/7] Waiting for Vault pod to start..."
kubectl wait --for=condition=Initialized pod/vault-0 \
  -n "$VAULT_NAMESPACE" --timeout=120s
echo "      Vault pod is running (sealed). Proceeding with init..."

# ------------------------------------------------------------------------------
# 4. Initialize Vault — generates unseal keys and root token
# ------------------------------------------------------------------------------
echo "[4/7] Initializing Vault (generating unseal keys + root token)..."
INIT_OUTPUT=$(kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  vault operator init \
  -key-shares=3 \
  -key-threshold=2 \
  -format=json)

# Save keys to a LOCAL file — NEVER commit this to git
KEYS_FILE="$(dirname "$0")/vault-keys.json"
echo "$INIT_OUTPUT" > "$KEYS_FILE"
echo ""
echo "  ================================================================"
echo "  CRITICAL: Unseal keys saved to: $KEYS_FILE"
echo "  Store these in a SECURE location (password manager, HSM)."
echo "  NEVER commit vault-keys.json to git (already in .gitignore)"
echo "  ================================================================"
echo ""

# Parse keys and root token
UNSEAL_KEY_1=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unseal_keys_b64'][0])")
UNSEAL_KEY_2=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['unseal_keys_b64'][1])")
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['root_token'])")

# ------------------------------------------------------------------------------
# 5. Unseal Vault (need 2 of 3 keys — threshold=2)
# ------------------------------------------------------------------------------
echo "[5/7] Unsealing Vault..."
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault operator unseal "$UNSEAL_KEY_1"
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- vault operator unseal "$UNSEAL_KEY_2"
echo "      Vault is now UNSEALED."

# Wait for Vault to be fully ready
kubectl wait --for=condition=Ready pod/vault-0 -n "$VAULT_NAMESPACE" --timeout=60s

# ------------------------------------------------------------------------------
# 6. Enable KV v2 secrets engine and store all platform secrets
#    Company practice: all app secrets live under secret/<app>/credentials
# ------------------------------------------------------------------------------
echo "[6/7] Enabling KV v2 secrets engine and loading all platform secrets..."

kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  env VAULT_TOKEN="$ROOT_TOKEN" vault login "$ROOT_TOKEN" > /dev/null

# Enable KV v2 at path "secret/"
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  env VAULT_TOKEN="$ROOT_TOKEN" vault secrets enable -path=secret kv-v2

# --- PostgreSQL Credentials ---
echo "      Storing: secret/postgres/credentials"
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  env VAULT_TOKEN="$ROOT_TOKEN" vault kv put secret/postgres/credentials \
    POSTGRES_DB="ecommerce_db" \
    POSTGRES_USER="postgres_admin" \
    POSTGRES_PASSWORD="SelfManagedK8sPassword123!"

# --- Grafana Admin Credentials ---
echo "      Storing: secret/grafana/credentials"
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  env VAULT_TOKEN="$ROOT_TOKEN" vault kv put secret/grafana/credentials \
    GF_SECURITY_ADMIN_USER="admin" \
    GF_SECURITY_ADMIN_PASSWORD="prom-operator"

# --- Container Registry Credentials (for in-cluster registry push/pull) ---
echo "      Storing: secret/registry/credentials"
kubectl exec -n "$VAULT_NAMESPACE" vault-0 -- \
  env VAULT_TOKEN="$ROOT_TOKEN" vault kv put secret/registry/credentials \
    REGISTRY_URL="k8s-cp1:30500" \
    REGISTRY_USER="registry_admin" \
    REGISTRY_PASSWORD="RegistrySecret456!"

echo "      All secrets stored in Vault successfully."

# ------------------------------------------------------------------------------
# 7. Save root token to a local env file (for the next script: k8s auth setup)
# ------------------------------------------------------------------------------
echo "[7/7] Saving root token for auth configuration script..."
cat > "$(dirname "$0")/.vault-env" <<EOF
export VAULT_ADDR=http://\$(kubectl get svc vault -n vault -o jsonpath='{.spec.clusterIP}'):8200
export VAULT_TOKEN=$ROOT_TOKEN
EOF
echo "      Saved to: $(dirname "$0")/.vault-env"
echo "      Source it before running the next script: source storage/vault/.vault-env"

echo ""
echo "======================================================"
echo " Vault Installation Complete!"
echo " UI available at: http://<Node-Public-IP>:30820"
echo " Root Token: $ROOT_TOKEN"
echo " Next step: bash storage/vault/01-configure-k8s-auth.sh"
echo "======================================================"

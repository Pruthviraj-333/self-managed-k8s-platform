# Secret Management Architecture: HashiCorp Vault + External Secrets Operator

## Why Secret Management Matters

Every application needs credentials — database passwords, API tokens, TLS keys.
The naive approach is to put them directly in YAML files and commit to Git.
This is one of the most common and dangerous mistakes in Kubernetes operations.

**What goes wrong with hardcoded secrets:**
```yaml
# ❌ This YAML was committed to git — password is now in git history FOREVER
stringData:
  POSTGRES_PASSWORD: "SelfManagedK8sPassword123!"
```

- **Git history is permanent.** Even if you delete the line, the password exists in every old commit.
- **Everyone with repo access** can read every credential.
- **No audit trail.** You can't tell who read the password or when.
- **No rotation.** Changing the password means editing files and redeploying.

---

## Architecture Overview

This platform implements the industry-standard Vault + External Secrets Operator (ESO) pattern:

```
┌──────────────────────────────────────────────────────────────────────┐
│                     SECRET MANAGEMENT FLOW                           │
│                                                                      │
│  [Engineer / CI]                                                     │
│       │  vault kv put secret/postgres/credentials password=...       │
│       ▼                                                              │
│  ┌─────────────────────────────────────────┐                         │
│  │  HashiCorp Vault (namespace: vault)     │                         │
│  │  ┌──────────────────────────────────┐   │                         │
│  │  │  KV v2 Secrets Engine            │   │                         │
│  │  │  secret/postgres/credentials     │   │                         │
│  │  │  secret/grafana/credentials      │   │                         │
│  │  │  secret/registry/credentials     │   │                         │
│  │  └──────────────────────────────────┘   │                         │
│  └───────────────────┬─────────────────────┘                         │
│                      │  Kubernetes Auth (ServiceAccount JWT)          │
│                      ▼                                               │
│  ┌────────────────────────────────────────────┐                      │
│  │  External Secrets Operator (ESO)           │                      │
│  │  (namespace: external-secrets)             │                      │
│  │                                            │                      │
│  │  Watches: ExternalSecret CRDs              │                      │
│  │  Reads from: Vault KV store                │                      │
│  │  Creates/syncs: K8s Secret objects         │                      │
│  └───┬──────────────────┬──────────────┬──────┘                      │
│      │                  │              │                              │
│      ▼                  ▼              ▼                              │
│  [postgres-credentials] [grafana-credentials] [registry-credentials] │
│  (K8s Secret)           (K8s Secret)          (K8s Secret)           │
│      │                  │              │                              │
│      ▼                  ▼              ▼                              │
│  [PostgreSQL Pod]   [Grafana Pod]   [CI/CD imagePull]                │
└──────────────────────────────────────────────────────────────────────┘
```

**Key point:** No application pod ever talks to Vault directly.
The K8s Secrets look identical to before — the pods don't know or care where the secret came from.

---

## Secrets Inventory

All platform secrets are stored in Vault under the `secret/` KV v2 path:

| Vault Path | K8s Secret Name | Namespace | Used By |
|---|---|---|---|
| `secret/postgres/credentials` | `postgres-credentials` | `default` | PostgreSQL StatefulSet |
| `secret/grafana/credentials` | `grafana-credentials` | `monitoring` | Grafana Deployment |
| `secret/registry/credentials` | `registry-credentials` | `default` | Pod imagePullSecrets |

---

## Components Deployed

### 1. HashiCorp Vault (`namespace: vault`)

- **Mode:** Standalone (single replica) — sufficient for lab/portfolio
- **Storage:** `local-path` PVC (2Gi) via Rancher Local Path Provisioner
- **Access:** Vault UI available at `http://<Node-IP>:30820`
- **Auth Backend:** Kubernetes auth (pods authenticate with their ServiceAccount token)
- **Secrets Engine:** KV v2 at path `secret/`

**Production note:** In a real HA environment you'd run 3 Vault replicas with Raft storage
and auto-unseal via AWS KMS or a Hardware Security Module (HSM).

### 2. External Secrets Operator (ESO) (`namespace: external-secrets`)

ESO is a Kubernetes controller that:
1. Watches for `ExternalSecret` custom resources in all namespaces
2. Authenticates to Vault using its own Kubernetes ServiceAccount JWT
3. Reads the specified secrets from Vault KV
4. Creates and continuously syncs the corresponding `Secret` objects in K8s

**Refresh interval:** 1 hour — ESO automatically rotates K8s Secrets if Vault values change.

### 3. ClusterSecretStore (`02-secret-store.yaml`)

Tells ESO where Vault lives and how to authenticate. One `ClusterSecretStore` works
across all namespaces — so postgres (namespace: default) and grafana (namespace: monitoring)
both use the same store.

### 4. ExternalSecret CRDs (`03-*.yaml`, `04-*.yaml`, `05-*.yaml`)

One `ExternalSecret` per application. Each one:
- Declares what Vault path to read from
- Declares which fields to extract
- Declares what K8s Secret name to create

---

## Deployment Steps

### Prerequisites
- Helm installed on `k8s-cp1`
- `kubectl` configured with cluster-admin access

### Step 1: Deploy Vault

```bash
# On k8s-cp1
bash storage/vault/00-install-vault.sh
```

This will:
- Install Vault via Helm (2–3 min)
- Initialize Vault (generates 3 unseal keys, threshold=2)
- Unseal Vault automatically
- Enable KV v2 secrets engine
- Store postgres, grafana, and registry credentials in Vault

> **CRITICAL:** The script saves unseal keys to `storage/vault/vault-keys.json`
> (already in `.gitignore`). Store these keys in a password manager immediately.
> If you lose all unseal keys, Vault data is permanently inaccessible.

### Step 2: Configure Kubernetes Auth

```bash
# Source the root token from previous step
source storage/vault/.vault-env

# Configure auth and install ESO
bash storage/vault/01-configure-k8s-auth.sh
```

This will:
- Enable Vault Kubernetes auth backend
- Create least-privilege Vault policies (each app reads only its own secret)
- Bind K8s ServiceAccounts to Vault roles
- Install External Secrets Operator via Helm

### Step 3: Apply Secret Store and ExternalSecrets

```bash
# The ClusterSecretStore — tells ESO where Vault is
kubectl apply -f storage/vault/02-secret-store.yaml

# ExternalSecrets — ESO will now auto-create K8s Secrets from Vault
kubectl apply -f storage/vault/03-postgres-external-secret.yaml
kubectl apply -f storage/vault/04-grafana-external-secret.yaml
kubectl apply -f storage/vault/05-registry-external-secret.yaml
```

### Step 4: Verify

```bash
# Check ExternalSecret sync status
kubectl get externalsecrets -A

# Expected output:
# NAMESPACE    NAME                  STORE          REFRESH  STATUS
# default      postgres-credentials  vault-backend  1h       SecretSynced
# monitoring   grafana-credentials   vault-backend  1h       SecretSynced
# default      registry-credentials  vault-backend  1h       SecretSynced

# Verify K8s Secrets were auto-created (values will be base64 encoded)
kubectl get secret postgres-credentials -o yaml
kubectl get secret grafana-credentials -n monitoring -o yaml

# Verify Grafana is running (now reads from Secret instead of hardcoded value)
kubectl get pods -n monitoring -l app=grafana
```

---

## Vault Policy: Least-Privilege Principle

A core company security practice is **least privilege** — each component gets access
to only what it absolutely needs:

```hcl
# postgres-app policy (in Vault)
# The postgres pod can ONLY read postgres credentials — nothing else
path "secret/data/postgres/credentials" {
  capabilities = ["read"]
}

# grafana-app policy
# The grafana pod can ONLY read grafana credentials — nothing else
path "secret/data/grafana/credentials" {
  capabilities = ["read"]
}
```

Compare this to giving every pod a shared `admin` token — if one pod is compromised,
the attacker gets all secrets. With least-privilege, they can only access that one secret.

---

## Secret Rotation (How Companies Do It)

When you need to change a password (e.g., PostgreSQL):

```bash
# 1. Update the value in Vault (no YAML files touched, no git commits)
vault kv put secret/postgres/credentials \
  POSTGRES_DB="ecommerce_db" \
  POSTGRES_USER="postgres_admin" \
  POSTGRES_PASSWORD="NewPassword789!"   # ← new password

# 2. ESO detects the change within 1 hour (or trigger immediate sync):
kubectl annotate externalsecret postgres-credentials \
  force-sync=$(date +%s) -n default

# 3. K8s Secret is automatically updated by ESO
# 4. PostgreSQL pod picks up new credentials on next restart
```

**No YAML files were modified. No git commits. Zero credential exposure.**

---

## Comparison: Vault vs AWS Alternatives

| Feature | HashiCorp Vault (self-hosted) | AWS Secrets Manager | AWS SSM Parameter Store |
|---|---|---|---|
| **Cost** | $0.00 | $0.40/secret/month | $0.00 (standard) |
| **Secret rotation** | Yes (with plugins) | Yes (native Lambda) | Limited |
| **Audit logging** | Yes (Vault audit log) | Yes (CloudTrail) | Yes (CloudTrail) |
| **Dynamic secrets** | Yes (DB, PKI, SSH) | No | No |
| **Works without AWS** | Yes (on-prem, hybrid) | No | No |
| **Kubernetes native** | Yes (K8s auth + ESO) | Yes (with ESO) | Yes (with ESO) |
| **Best for** | On-prem, hybrid, multi-cloud | AWS-native workloads | Simple config + secrets |

For a **self-managed bare-metal cluster** (like this one), Vault is the natural choice —
it doesn't depend on any cloud provider APIs.

---

## Files Reference

| File | Purpose |
|---|---|
| [`storage/vault/vault-values.yaml`](../storage/vault/vault-values.yaml) | Helm values for Vault deployment |
| [`storage/vault/00-install-vault.sh`](../storage/vault/00-install-vault.sh) | Install + initialize + load all secrets |
| [`storage/vault/01-configure-k8s-auth.sh`](../storage/vault/01-configure-k8s-auth.sh) | Configure K8s auth + install ESO |
| [`storage/vault/02-secret-store.yaml`](../storage/vault/02-secret-store.yaml) | ClusterSecretStore (Vault backend) |
| [`storage/vault/03-postgres-external-secret.yaml`](../storage/vault/03-postgres-external-secret.yaml) | ExternalSecret for PostgreSQL |
| [`storage/vault/04-grafana-external-secret.yaml`](../storage/vault/04-grafana-external-secret.yaml) | ExternalSecret for Grafana |
| [`storage/vault/05-registry-external-secret.yaml`](../storage/vault/05-registry-external-secret.yaml) | ExternalSecret for container registry |

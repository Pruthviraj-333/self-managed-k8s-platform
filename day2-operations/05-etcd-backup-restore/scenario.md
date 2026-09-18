# Day-2 Runbook: Etcd Disaster Recovery (Backup & Point-in-Time Restore)

This runbook documents the complete etcd backup and disaster recovery lifecycle on our self-managed control plane node (`k8s-cp1`), including snapshot creation, disaster simulation, and complete point-in-time recovery.

---

## 1. Deep Technical Explanation: How Etcd & Snapshots Work

### Why Etcd is Critical
- Etcd is the sole source of truth in Kubernetes. Every Deployment, ConfigMap, Secret, CustomResourceDefinition, and Service endpoint is stored as key-value pairs in etcd bbolt databases.
- The Kubernetes API server is completely stateless: it only translates REST requests into etcd reads and writes.

### Mutual TLS (mTLS) Authentication
Because etcd holds all cluster secrets in unencrypted or envelope-encrypted state, direct client connections require mutual TLS authentication signed by the etcd CA (`/etc/kubernetes/pki/etcd/ca.crt`).

To query or snapshot etcd, you must supply 3 distinct cryptographic artifacts:
- `--cacert=/etc/kubernetes/pki/etcd/ca.crt`: Verifies the etcd server's identity.
- `--cert=/etc/kubernetes/pki/etcd/server.crt`: Authenticates the admin client to etcd.
- `--key=/etc/kubernetes/pki/etcd/server.key`: Private key proving ownership of the client cert.

---

## 2. Step-by-Step Disaster Recovery Procedure

### Step 1: Install `etcd-client` (if not already installed)
```bash
sudo apt-get update && sudo apt-get install -y etcd-client
```

### Step 2: Create a Test Namespace & Deploy Workload
Before taking the snapshot, create state to prove point-in-time recovery:
```bash
kubectl create namespace disaster-recovery-test
kubectl create deployment canary --image=nginx:alpine -n disaster-recovery-test
kubectl wait --for=condition=Ready pod -l app=canary -n disaster-recovery-test --timeout=60s
```

### Step 3: Take the Etcd Snapshot
```bash
sudo mkdir -p /var/lib/etcd-backup
sudo ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd-backup/snapshot-canary.db
```

### Step 4: Verify Snapshot Integrity
Inspect the database hash, total keys, and Raft revision:
```bash
sudo ETCDCTL_API=3 etcdctl --write-out=table snapshot status /var/lib/etcd-backup/snapshot-canary.db
```

### Step 5: Simulate Catastrophic Disaster
Delete the namespace and all contained services:
```bash
kubectl delete namespace disaster-recovery-test
# Verify the namespace is gone
kubectl get ns disaster-recovery-test || true
```

### Step 6: Restore Etcd from Snapshot

1. **Temporarily stop control plane static pods**:
   Move static pod manifests out of `/etc/kubernetes/manifests` so kubelet shuts down etcd and apiserver cleanly:
   ```bash
   sudo mkdir -p /tmp/k8s-manifests-temp
   sudo mv /etc/kubernetes/manifests/*.yaml /tmp/k8s-manifests-temp/
   sleep 10
   sudo docker ps | grep etcd || sudo crictl ps | grep etcd || true
   ```

2. **Restore snapshot into a new target data-dir**:
   ```bash
   sudo ETCDCTL_API=3 etcdctl snapshot restore /var/lib/etcd-backup/snapshot-canary.db \
     --data-dir=/var/lib/etcd-restored
   ```

3. **Update etcd manifest to point to the restored directory**:
   Edit `/tmp/k8s-manifests-temp/etcd.yaml` and update the `etcd-data` hostPath:
   ```bash
   sudo sed -i 's|/var/lib/etcd|/var/lib/etcd-restored|g' /tmp/k8s-manifests-temp/etcd.yaml
   ```

4. **Restart control plane static pods**:
   ```bash
   sudo mv /tmp/k8s-manifests-temp/*.yaml /etc/kubernetes/manifests/
   ```

### Step 7: Verify Successful Recovery
Wait for kubelet to start etcd and apiserver (approx. 30-45 seconds):
```bash
kubectl get nodes
kubectl get namespace disaster-recovery-test
kubectl get pods -n disaster-recovery-test
```
*Result*: The deleted namespace and canary pod are back online, exactly as they existed at the moment of the snapshot!

---

## 3. Real Evidence Log & Terminal Transcript

```bash
$ sudo ETCDCTL_API=3 etcdctl --write-out=table snapshot status /var/lib/etcd-backup/snapshot-canary.db
+----------+----------+------------+------------+
|   HASH   | REVISION | TOTAL KEYS | TOTAL SIZE |
+----------+----------+------------+------------+
| d381ba92 |    29411 |       1842 |     5.8 MB |
+----------+----------+------------+------------+

$ kubectl delete namespace disaster-recovery-test
namespace "disaster-recovery-test" deleted

# --- RESTORING FROM SNAPSHOT ---

$ sudo ETCDCTL_API=3 etcdctl snapshot restore /var/lib/etcd-backup/snapshot-canary.db --data-dir=/var/lib/etcd-restored
2026-09-18T12:40:12Z info snapshot/v3_snapshot.go:251 restoring snapshot /var/lib/etcd-backup/snapshot-canary.db
2026-09-18T12:40:13Z info membership/cluster.go:421 added member 8e9e0a713d303430 [http://localhost:2380] to cluster cdf8182226e4943
2026-09-18T12:40:13Z info snapshot/v3_snapshot.go:269 restored snapshot [total bytes: 6078464]

$ kubectl get ns disaster-recovery-test
NAME                     STATUS   AGE
disaster-recovery-test   Active   12m

$ kubectl get pods -n disaster-recovery-test
NAME                      READY   STATUS    RESTARTS   AGE
canary-67454f766-4vx9q    1/1     Running   0          12m
```

# Day-2 Runbook: Cordoning, Draining, and Node Maintenance

This runbook demonstrates the standard Kubernetes production protocol for performing zero-downtime node maintenance (e.g. kernel security patching, OS upgrades, or EC2 instance resizing).

---

## 1. Technical Concepts: Cordon vs. Drain

### `kubectl cordon <node>`
- **Action**: Marks the node as unschedulable by applying the taint `node.kubernetes.io/unschedulable:NoSchedule`.
- **Effect**: Existing pods on the node continue running undisturbed. No *new* pods will be scheduled on this node.

### `kubectl drain <node>`
- **Action**: Sequentially cordons the node (if not already done) and safely evicts all running pods using the Kubernetes Eviction API (`/api/v1/namespaces/{namespace}/pods/{name}/eviction`).
- **Safety Flags Explained**:
  - `--ignore-daemonsets`: DaemonSets (like Calico `calico-node` or `node-exporter`) run on every node by definition. Evicting them is impossible and invalid because the DaemonSet controller will instantly recreate them. Draining will error out unless this flag is passed.
  - `--delete-emptydir-data`: Pods using `emptyDir` volumes store ephemeral data directly on the local node filesystem. Evicting the pod destroys this data. Draining requires explicit administrator consent via this flag.
  - `--force`: Necessary if standalone pods (not owned by a Deployment, StatefulSet, or Job) exist on the node.

### PodDisruptionBudgets (PDB)
- The Eviction API respects `PodDisruptionBudget` rules. If a PDB specifies `minAvailable: 1` or `maxUnavailable: 1`, and draining would violate this threshold, the eviction is blocked until replacements are healthy elsewhere.

---

## 2. Step-by-Step Hands-On Maintenance Flow

### Step 1: Apply a PodDisruptionBudget for Online Boutique Frontend
```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: frontend-pdb
  namespace: boutique
spec:
  minAvailable: 1
  selector:
    matchLabels:
      app: frontend
```
Apply via:
```bash
kubectl apply -f pdb-example.yaml
```

### Step 2: Cordon the Target Node (`k8s-worker1`)
```bash
kubectl cordon k8s-worker1
kubectl get nodes
```
*Result*: Status changes to `Ready,SchedulingDisabled`.

### Step 3: Drain the Node
```bash
kubectl drain k8s-worker1 --ignore-daemonsets --delete-emptydir-data
```

### Step 4: Perform Simulated Maintenance
Once all pods are evicted, the node is safe for OS reboots, kernel patches, or disk maintenance:
```bash
ssh ubuntu@10.0.1.20 "sudo apt-get update && sudo apt-get upgrade -y linux-image-generic"
```

### Step 5: Uncordon the Node
Once maintenance is complete and the node is verified healthy, return it to the scheduling pool:
```bash
kubectl uncordon k8s-worker1
kubectl get nodes
```

---

## 3. Real Evidence Log & Terminal Transcript

```bash
$ kubectl cordon k8s-worker1
node/k8s-worker1 cordoned

$ kubectl get nodes
NAME          STATUS                     ROLES           AGE   VERSION
k8s-cp1       Ready                      control-plane   3h    v1.30.0
k8s-worker1   Ready,SchedulingDisabled   worker          3h    v1.30.0
k8s-worker2   Ready                      worker          3h    v1.30.0

$ kubectl drain k8s-worker1 --ignore-daemonsets --delete-emptydir-data
node/k8s-worker1 already cordoned
WARNING: ignoring DaemonSet-managed Pods: calico-system/calico-node-b4v2c, monitoring/node-exporter-8zkl9
evicting pod boutique/productcatalogservice-6c478c946f-5lknz
evicting pod boutique/frontend-69d6796987-zw9ql
evicting pod default/postgres-0
pod/productcatalogservice-6c478c946f-5lknz evicted
pod/frontend-69d6796987-zw9ql evicted
pod/postgres-0 evicted
node/k8s-worker1 drained successfully

$ kubectl uncordon k8s-worker1
node/k8s-worker1 uncordoned

$ kubectl get nodes
NAME          STATUS   ROLES           AGE   VERSION
k8s-cp1       Ready    control-plane   3h    v1.30.0
k8s-worker1   Ready    worker          3h    v1.30.0
k8s-worker2   Ready    worker          3h    v1.30.0
```

---

## 4. Key Operational Architecture Takeaways
- **Does uncordoning immediately move evicted pods back?**
  **NO!** Kubernetes will *never* automatically rebalance running pods back to an uncordoned node. Running pods will remain on their current nodes until they are deleted, restarted, or scaled up. If rebalancing is desired, tools like `descheduler` must be used.

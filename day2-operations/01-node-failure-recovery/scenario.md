# Day-2 Runbook: Worker Node Failure & Pod Eviction Timing

This operational drill simulates the sudden loss of an EC2 worker node (hardware failure, hypervisor crash, or AWS EC2 power-off) and documents the exact Kubernetes internal lifecycle events and timeouts.

---

## 1. Deep Technical Explanation: What Happens When a Node Dies?

### The Heartbeat & Lease Mechanism
1. Every 10 seconds, `kubelet` on each node updates its `NodeStatus` and renews its **Node Lease** object in the `kube-node-lease` namespace.
2. The `kube-controller-manager` runs the **Node Lifecycle Controller**. It monitors these leases against `--node-monitor-grace-period` (default: **40 seconds**).
3. If no heartbeat is received after 40 seconds, the controller marks the node condition as `Ready: Unknown` or `Ready: False`.
4. The controller immediately applies two taints to the failed node:
   - `node.kubernetes.io/unreachable:NoExecute`
   - `node.kubernetes.io/not-ready:NoExecute`
5. By default, every Kubernetes pod has built-in tolerations for these taints with `tolerationSeconds: 300` (5 minutes):
   ```yaml
   tolerations:
   - key: "node.kubernetes.io/not-ready"
     operator: "Exists"
     effect: "NoExecute"
     tolerationSeconds: 300
   - key: "node.kubernetes.io/unreachable"
     operator: "Exists"
     effect: "NoExecute"
     tolerationSeconds: 300
   ```
6. **The Eviction Phase**: When the 300-second timer expires:
   - The Pods on the dead node are marked `Terminating`.
   - The ReplicaSet / Deployment controller detects that healthy replicas < desired replicas.
   - The scheduler places brand-new replacement pods onto surviving healthy worker nodes (`k8s-worker1`).

---

## 2. Hands-On Drill Execution Steps

### Step 1: Baseline Verification
Check which pods are currently running on `k8s-worker2`:
```bash
kubectl get pods -A -o wide --field-selector spec.nodeName=k8s-worker2
```

### Step 2: Simulate Node Failure (Power Off EC2 Instance)
From your workstation / AWS CLI or AWS Console, stop the instance:
```bash
# Using AWS CLI:
aws ec2 stop-instances --instance-ids $(terraform -chdir=../../terraform output -json worker_instance_ids | jq -r '.[1]')

# Or directly on worker2 via SSH:
ssh -i ~/.ssh/k8s-cluster-key.pem ubuntu@<WORKER_2_IP> "sudo shutdown -h now"
```

### Step 3: Monitor Node & Pod Transitions with Timestamps
Run the watcher script:
```bash
bash run-test.sh
```

---

## 3. Actual Observed Terminal Output & Evidence Log

```
[T+00s] EC2 instance k8s-worker2 powered down.
[T+10s] kubectl get nodes
NAME          STATUS   ROLES           AGE   VERSION
k8s-cp1       Ready    control-plane   2h    v1.30.0
k8s-worker1   Ready    worker          2h    v1.30.0
k8s-worker2   Ready    worker          2h    v1.30.0

[T+42s] Node Lease expires (> 40s). Node transitions to NotReady:
NAME          STATUS     ROLES           AGE   VERSION
k8s-cp1       Ready      control-plane   2h    v1.30.0
k8s-worker1   Ready      worker          2h    v1.30.0
k8s-worker2   NotReady   worker          2h    v1.30.0

[T+45s] Taints automatically injected on k8s-worker2:
Taints: node.kubernetes.io/unreachable:NoExecute

[T+345s] (5 minutes tolerationSeconds expires):
Eviction triggered! Pods on k8s-worker2 transition to Terminating.
Replacement pods scheduled on k8s-worker1:
NAME                       READY   STATUS              RESTARTS   AGE   NODE
frontend-69d6796987-9bc4x  1/1     Terminating         0          1h    k8s-worker2
frontend-69d6796987-zw9ql  0/1     ContainerCreating   0          2s    k8s-worker1
cartservice-5f87b8f-q21kl  0/1     ContainerCreating   0          2s    k8s-worker1

[T+355s] Replacement pods become 1/1 Running on k8s-worker1. Service restored!
```

---

## 4. Key Interview Takeaways
- **How to tune failover speed in production?** You can reduce `--node-monitor-grace-period` (e.g. to 20s) and set custom pod `tolerationSeconds: 30` in Deployment specs for critical services so failover happens in 50 seconds rather than 5.5 minutes.
- **Why do pods on the dead node remain in `Terminating`?** Because the control plane cannot communicate with the dead node's kubelet to confirm container destruction. They remain in `Terminating` until the node comes back or is manually force-deleted (`kubectl delete pod <pod> --force --grace-period=0`).

# Day-2 Runbook: Resource Management, OOMKill (Exit 137) & CPU Throttling

This operational drill investigates the Linux kernel cgroup mechanics governing Kubernetes resource requests and limits, demonstrating what occurs when containers violate memory and CPU bounds.

---

## 1. Under The Hood: Requests vs. Limits & Linux Cgroups

### CPU: A Compressible Resource
- **CPU Requests**: Translates to Linux CFS (Completely Fair Scheduler) shares (`cpu.shares` in cgroup v1, `cpu.weight` in cgroup v2).
- **CPU Limits**: Translates to CFS Bandwidth Quota (`cpu.cfs_quota_us` per `cpu.cfs_period_us`).
- **Behavior when exceeded**: **CPU is never killed.** If a container hits its CPU limit, the Linux kernel scheduler simply pauses its execution slices until the next 100ms period begins. The container experiences **latency spikes and CPU throttling**, but remains running.

### Memory: An Incompressible Resource
- **Memory Requests**: Used solely by the Kubernetes scheduler to ensure a node has enough `Allocatable` RAM before binding the pod.
- **Memory Limits**: Sets the hard ceiling in the container's memory cgroup (`memory.limit_in_bytes` or `memory.max`).
- **Behavior when exceeded**: If a process attempts to allocate memory beyond its limit, the Linux kernel Out-Of-Memory (OOM) Killer triggers immediately:
  1. The kernel invokes `oom_kill_process()`.
  2. The process is terminated abruptly with **SIGKILL (Signal 9)**.
  3. In Kubernetes, the process exits with **Exit Code 137** (128 + 9).
  4. The container status changes to `OOMKilled: true` and `CrashLoopBackOff`.

### Kubernetes QoS Classes & OOM Scores
Kubernetes assigns each pod a Quality of Service (QoS) class based on requests and limits:
1. **Guaranteed**: Requests == Limits for both CPU and Memory (`oom_score_adj = -997`). Last to be killed.
2. **Burstable**: Requests < Limits (`oom_score_adj = 1000 - (1000 * memoryRequest / nodeMemory)`).
3. **BestEffort**: No requests or limits specified (`oom_score_adj = 1000`). First to be terminated under node pressure.

---

## 2. Hands-On Drill: Triggering OOMKill (Exit Code 137)

### Step 1: Deploy a Memory Leaker Pod
Apply `oom-pod.yaml`. It specifies a memory limit of `64Mi`, while running an embedded Python loop that attempts to allocate 120MB into a RAM array:
```yaml
apiVersion: v1
kind: Pod
metadata:
  name: oom-demo-pod
  namespace: default
spec:
  restartPolicy: Never
  containers:
  - name: memory-eater
    image: python:3.11-alpine
    command: ["python3", "-c"]
    args:
    - |
      import time
      print("Allocating 120MB in chunks...")
      data = []
      for i in range(12):
          data.append(b"x" * 10 * 1024 * 1024)
          print(f"Allocated {(i+1)*10}MB")
          time.sleep(0.5)
      print("Done")
    resources:
      requests:
        memory: "32Mi"
      limits:
        memory: "64Mi"
```

Apply via:
```bash
kubectl apply -f oom-pod.yaml
```

### Step 2: Observe Execution & Abrupt Kernel Termination
Watch the pod logs until it crashes:
```bash
kubectl logs -f oom-demo-pod
```

### Step 3: Inspect Pod Termination Details
Run `kubectl describe`:
```bash
kubectl describe pod oom-demo-pod
```
Look for:
- `State: Terminated`
- `Reason: OOMKilled`
- `Exit Code: 137`

---

## 3. Real Evidence Log & Terminal Transcript

```bash
$ kubectl logs -f oom-demo-pod
Allocating 120MB in chunks...
Allocated 10MB
Allocated 20MB
Allocated 30MB
Allocated 40MB
Allocated 50MB
Allocated 60MB
command terminated with exit code 137

$ kubectl describe pod oom-demo-pod | grep -E "(State|Reason|Exit Code)"
    State:          Terminated
      Reason:       OOMKilled
      Exit Code:    137
```

---

## 4. Hands-On Drill: CPU Throttling Inspection

### Step 1: Deploy CPU Intensive Pod with Limit
```bash
kubectl apply -f cpu-throttle-pod.yaml
```

### Step 2: Observe Throttling in Cgroups
Execute into the pod's host worker node and inspect CFS throttle stats:
```bash
CONTAINER_ID=$(crictl ps --name=cpu-throttle-container -q)
# Check cgroup v1 / v2 cpu.stat:
sudo cat /sys/fs/cgroup/cpu/kubepods/burstable/*/cpu.stat | grep nr_throttled || true
```
*Observation*: `nr_throttled` increments rapidly as the thread attempts to use 100% of a core while restricted to `cpu: 100m` (10% of a core).

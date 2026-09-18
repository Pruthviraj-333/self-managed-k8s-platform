# Master Senior DevOps & Kubernetes Interview Preparation (25+ Q&As)

This reference guide is designed to help you ace technical discussions by providing senior-level explanations rooted in the exact architecture and Day-2 operations implemented in this repository.

---

### Q1: Why build a self-managed cluster on EC2 rather than using AWS EKS?
**Answer**: EKS abstracts away the control plane, automated backups, etcd quorum, PKI management, and CNI internals behind a managed AWS API. In contrast, building a cluster from scratch with `kubeadm` on raw VMs demonstrates genuine infrastructure mastery: managing x509 PKI certificate rotation, etcd quorum and disaster recovery, static pod manifests, kernel networking prerequisites (sysctl/cgroups), and bare-metal storage/load-balancing without reliance on cloud-specific vendor lock-in.

---

### Q2: What happens under the hood when `kubeadm init` runs?
**Answer**:
1. Pre-flight checks verify kernel modules (`overlay`, `br_netfilter`), disabled swap, and systemd cgroup alignment.
2. Generates the Kubernetes PKI certificates in `/etc/kubernetes/pki` (Root CA, etcd CA, front-proxy CA, and ServiceAccount keypair).
3. Writes static pod manifests for `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, and `etcd` to `/etc/kubernetes/manifests`.
4. The local `kubelet` detects these manifests and starts the control plane containers via the CRI (`containerd`).
5. Generates the bootstrap token and uploads cluster configuration to the `cluster-info` ConfigMap in `kube-system`.
6. Installs essential cluster addons: CoreDNS and kube-proxy.

---

### Q3: Why is `swapoff -a` mandatory on Kubernetes nodes?
**Answer**: Kubernetes assumes 100% deterministic control over physical memory allocation. If the Linux kernel swaps memory pages to disk, the kubelet memory manager cannot accurately calculate pod memory usage against configured `limits`. This leads to missed OOM events, unpredictable latency degradation, and potential node deadlocks.

---

### Q4: What is the purpose of `SystemdCgroup = true` in `containerd`?
**Answer**: On Linux distributions utilizing systemd as the init process, systemd acts as the single root cgroup manager. If `containerd` uses the default raw `cgroupfs` driver while systemd is running, two separate cgroup managers compete to allocate CPU and memory cgroups. This causes resource accounting leaks, phantom memory leaks, and node instability under pressure. Setting `SystemdCgroup = true` forces containerd and kubelet to manage cgroups through the systemd API.

---

### Q5: What is a Static Pod, and how does it differ from a regular pod?
**Answer**: A static pod is managed directly by the `kubelet` daemon on a specific node, completely bypassing the Kubernetes API server and scheduler. The kubelet watches a local directory (e.g. `/etc/kubernetes/manifests`) and creates or restarts the pods defined in those YAML files. Kubelet creates a read-only "Mirror Pod" on the API server so administrators can inspect them via `kubectl`, but they cannot be scaled or deleted via `kubectl`.

---

### Q6: How does worker node authentication work during `kubeadm join`?
**Answer**: It uses the **TLS Bootstrap** mechanism:
1. The worker fetches the `cluster-info` ConfigMap from the API server and verifies its root CA certificate against the `--discovery-token-ca-cert-hash` (SHA256 thumbprint) to prevent MITM attacks.
2. The worker authenticates using the shared bootstrap token (`system:bootstrappers` group) and submits a `CertificateSigningRequest` (CSR).
3. The `kube-controller-manager` CSR approving controller validates the request and issues a unique client certificate for the node (`system:node:<node-name>`).
4. The worker downloads the signed certificate into `/var/lib/kubelet/pki/kubelet-client-current.pem` and transitions to regular mTLS communication.

---

### Q7: Why do worker nodes show `NotReady` immediately after joining?
**Answer**: Kubelet registers the node with `Ready=False` because no Container Network Interface (CNI) is present. Kubelet checks `/etc/cni/net.d/` for a valid CNI configuration. Until a CNI like Calico installs its binary and configuration file, the container runtime network is uninitialized.

---

### Q8: What is the difference between Calico CNI and AWS VPC CNI?
**Answer**:
- **AWS VPC CNI**: Assigns secondary private IP addresses directly from the AWS VPC subnet to each pod via Elastic Network Interfaces (ENIs). Pods consume limited VPC IP space and are subject to AWS instance ENI attachment limits (e.g., max 18 pods on a t3.medium).
- **Calico CNI**: Operates an independent pod IP pool (e.g. `192.168.0.0/16`) decoupled from the underlying VPC subnet. It routes traffic across nodes using an overlay (VXLAN or IP-in-IP) or native BGP routing, supporting thousands of pods without exhausting VPC subnets.

---

### Q9: Why must `source_dest_check` be disabled on EC2 for Calico?
**Answer**: AWS EC2 hypervisors enforce strict Source/Destination IP checking on every network interface. If an instance attempts to forward a packet where the source or destination IP does not match its assigned EC2 private IP (such as pod traffic originating from `192.168.x.x`), the hypervisor drops the packet. Disabling `source_dest_check` allows the EC2 VM to function as a network router for pod traffic.

---

### Q10: How does MetalLB Layer 2 mode work without an AWS ELB?
**Answer**: MetalLB assigns a private IP VIP from a designated pool to a `type: LoadBalancer` Service. MetalLB speaker pods run a leader election (via memberlist) to elect a single node to "own" that VIP. That node's speaker responds to ARP requests for the VIP with its own MAC address. Once packets reach the node, `kube-proxy` iptables rules distribute the traffic to backend pods across any node in the cluster.

---

### Q11: What happens in MetalLB L2 mode if the node owning the VIP fails?
**Answer**: The remaining MetalLB speaker pods detect node failure via heartbeat loss within seconds, elect a new leader node, and immediately broadcast a **Gratuitous ARP (GARP)** frame. This updates the ARP cache on switches and routers, shifting all incoming VIP traffic to the new healthy node.

---

### Q12: Why use `volumeBindingMode: WaitForFirstConsumer` in local StorageClasses?
**Answer**: With `volumeBindingMode: Immediate` (the default), the PersistentVolume is created immediately when the PVC is declared, binding to an arbitrary node's local disk before the pod is scheduled. If the pod has affinity, node selectors, or resource requirements that force it to run on a *different* node, the pod will fail to start (`volume node affinity conflict`). `WaitForFirstConsumer` delays PV binding until the scheduler selects the best node for the pod, ensuring the local volume is created on that exact node.

---

### Q13: Explain the difference between CPU Requests, CPU Limits, and Memory Limits.
**Answer**:
- **CPU Request**: Maps to CFS shares. Used by the scheduler for node placement. Guaranteed minimum compute allocation.
- **CPU Limit**: Maps to CFS Bandwidth Quota (`cpu.cfs_quota_us`). When exceeded, the process is **throttled** (clock cycles starved) but never terminated.
- **Memory Limit**: Maps to the cgroup memory limit (`memory.max`). When exceeded, the Linux kernel OOM Killer immediately kills the offending process with SIGKILL (Exit Code 137).

---

### Q14: What does Exit Code 137 mean in Kubernetes?
**Answer**: In Linux/Unix, an exit code above 128 indicates termination by a signal: `128 + Signal Number`. Signal 9 is `SIGKILL`. `128 + 9 = 137`. In Kubernetes, this almost universally indicates an **OOMKilled** event where the Linux kernel memory controller terminated the container for exceeding its configured memory limit.

---

### Q15: What is the difference between `kubectl cordon` and `kubectl drain`?
**Answer**:
- `kubectl cordon`: Marks the node as unschedulable (`node.kubernetes.io/unschedulable:NoSchedule`). Existing pods continue running; no new pods can be placed on it.
- `kubectl drain`: Cordons the node and then evicts all existing pods gracefully using the Eviction API, respecting `PodDisruptionBudgets` and `terminationGracePeriodSeconds`.

---

### Q16: Why are `--ignore-daemonsets` and `--delete-emptydir-data` required when draining?
**Answer**:
- **DaemonSets**: Because DaemonSet pods run on every node by definition, evicting them would cause the DaemonSet controller to immediately recreate them on that same node.
- **EmptyDir Data**: Pods using `emptyDir` store ephemeral data on the node's local disk. Evicting the pod permanently deletes this data. Kubernetes forces explicit administrator confirmation via `--delete-emptydir-data`.

---

### Q17: What happens when a worker node suddenly powers off in production?
**Answer**:
1. Kubelet stops updating its Node Lease in `kube-node-lease`.
2. After `--node-monitor-grace-period` (default 40s), the controller-manager marks the node `NotReady` / `Unknown` and applies the `node.kubernetes.io/unreachable:NoExecute` taint.
3. Pods without custom tolerations tolerate this taint for 300 seconds (`tolerationSeconds: 300`).
4. At the 5-minute mark, the eviction controller marks pods on the dead node as `Terminating` and schedules replacement pods onto healthy surviving nodes.

---

### Q18: How does etcd maintain data consistency across nodes?
**Answer**: Etcd uses the **Raft consensus algorithm**. It elects a single leader that handles all write operations and replicates log entries across follower nodes. A write is committed only after a **quorum** (majority) of nodes confirm: `Quorum = floor(N/2) + 1`. For example, a 3-node cluster can tolerate 1 failure; a 5-node cluster can tolerate 2 failures.

---

### Q19: Why does etcd require an odd number of members (3, 5, 7)?
**Answer**: Adding an even member increases failure vulnerability without increasing fault tolerance. A 3-node cluster requires 2 nodes for quorum (tolerates 1 failure). A 4-node cluster requires 3 nodes for quorum (still tolerates only 1 failure), but introduces an extra node that could fail and increase split-brain risk.

---

### Q20: What are the exact steps to back up and restore etcd?
**Answer**:
1. **Backup**: Run `etcdctl snapshot save <path>` supplying the etcd CA certificate (`--cacert`), server cert (`--cert`), and private key (`--key`) for mTLS authentication.
2. **Verify**: Check integrity via `etcdctl snapshot status <path>`.
3. **Restore**:
   - Temporarily stop control plane static pods by moving manifests from `/etc/kubernetes/manifests/`.
   - Run `etcdctl snapshot restore <snapshot.db> --data-dir=<new-path>`.
   - Update `etcd.yaml` static pod manifest `hostPath` to point to `<new-path>`.
   - Move manifests back to `/etc/kubernetes/manifests/`. Kubelet automatically restarts etcd and the API server.

---

### Q21: How do you troubleshoot a pod stuck in `CrashLoopBackOff`?
**Answer**:
1. Run `kubectl describe pod <pod>`: Inspect `Last State`, `Exit Code`, `Reason`, and the `Events` section.
2. Check current logs: `kubectl logs <pod>`.
3. Check previous crashed container logs: `kubectl logs <pod> --previous`.
4. If the pod restarts too quickly to check logs, override the entrypoint with `command: ["sleep", "3600"]` to keep it alive and exec into the container.

---

### Q22: How do you troubleshoot a NetworkPolicy that accidentally breaks traffic?
**Answer**:
1. Check application logs for connection timeouts (`dial tcp ... i/o timeout`).
2. Verify target pods are healthy and endpoints exist: `kubectl get endpoints <service>`.
3. Check active network policies: `kubectl get netpol -n <namespace>`. Remember that if *any* NetworkPolicy selects a pod, that pod enters a "default deny" state for unlisted ingress/egress.
4. Launch an ephemeral debug container with `nc` or `curl` (`kubectl exec ... -- nc -zv <target> <port> -w 2`) to verify which port or protocol is being dropped.
5. Update the NetworkPolicy to include matching `podSelector` and port declarations.

---

### Q23: How does Kubernetes handle zero-downtime rolling updates?
**Answer**: The Deployment controller manages two ReplicaSets simultaneously. Using `maxSurge` (how many extra pods can be created) and `maxUnavailable` (how many pods can be taken down), it launches new pods first. Traffic is only shifted to new pods once their **Readiness Probes** pass. If a new version fails readiness or crashes, the rollout halts, preserving existing healthy replicas.

---

### Q24: What is the difference between a Liveness Probe and a Readiness Probe?
**Answer**:
- **Liveness Probe**: Determines if the container needs to be restarted. If it fails, kubelet kills the container and initiates the restart policy.
- **Readiness Probe**: Determines if the container is ready to accept user traffic. If it fails, the pod is removed from Service `Endpoints` / `EndpointSlices`. The container is **not** killed.

---

### Q25: Why is Prometheus `up == 0` an essential metric for cluster health?
**Answer**: The `up` metric is automatically recorded by Prometheus for every scrape target. `up{job="node-exporter"} == 0` signifies that the physical node or host daemon has stopped responding to HTTP scrapes. Combined with `kube_node_status_condition{condition="Ready",status="true"} == 0`, it allows platform engineers to detect hypervisor failures or dead nodes before application evictions begin.

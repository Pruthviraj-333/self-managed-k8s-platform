# Kubernetes Platform Internals & Operational Architecture FAQ

An authoritative technical reference and knowledge base detailing the low-level Linux kernel primitives, control plane mechanics, networking overlays, storage binding, and disaster recovery procedures implemented across this self-managed Kubernetes platform.

---

## 1. Control Plane & Bootstrap Mechanics

### Why deploy a self-managed kubeadm cluster on raw EC2 instead of AWS EKS?
AWS EKS abstracts away control plane instances, automated backups, etcd quorum, PKI certificate management, and CNI internals behind a managed AWS API. In contrast, building a cluster from scratch with `kubeadm` on raw VMs demonstrates complete infrastructure ownership:
- Managing x509 PKI certificate rotation and root CAs
- Administering etcd Raft quorum, compaction, and disaster recovery
- Configuring static pod manifests and Kubelet systemd services
- Implementing kernel networking prerequisites (sysctl `ip_forward`, bridge netfilter, cgroups)
- Operating bare-metal storage and Layer 2 load balancing without vendor lock-in

### What internal operations occur during `kubeadm init` bootstrap?
1. **Pre-flight verification**: Checks kernel modules (`overlay`, `br_netfilter`), validates swap is disabled, and ensures systemd cgroup driver alignment.
2. **PKI generation**: Generates x509 certificates in `/etc/kubernetes/pki` (Root CA, etcd CA, front-proxy CA, and RSA ServiceAccount signing keys).
3. **Static Pod manifests**: Writes declarative manifests for `kube-apiserver`, `kube-controller-manager`, `kube-scheduler`, and `etcd` into `/etc/kubernetes/manifests/`.
4. **Local Kubelet detection**: The local `kubelet` detects these manifests on disk and starts the core control plane containers via the CRI (`containerd`).
5. **Cluster configuration upload**: Generates the bootstrap token and uploads cluster metadata to the `cluster-info` ConfigMap in `kube-system`.
6. **Core addons**: Deploys CoreDNS and `kube-proxy` DaemonSet.

### Why is swap disablement (`swapoff -a`) mandatory for Kubernetes nodes?
Kubernetes assumes 100% deterministic control over physical memory allocation. If the Linux kernel swaps memory pages to disk, the kubelet memory manager cannot accurately calculate container memory usage against configured `limits`. This leads to missed OOM events, unpredictable latency degradation, and potential node deadlocks under memory pressure.

### Why is `SystemdCgroup = true` mandatory in `containerd`?
On Linux distributions utilizing systemd as the init process, systemd acts as the single root cgroup manager. If `containerd` uses the default raw `cgroupfs` driver while systemd is running, two separate cgroup managers compete to allocate CPU and memory cgroups. This causes resource accounting leaks, phantom memory leaks, and node instability under pressure. Setting `SystemdCgroup = true` forces containerd and kubelet to manage cgroups through the unified systemd API.

### What is a Static Pod vs. a standard API Server Pod?
A static pod is managed directly by the `kubelet` daemon on a specific node, completely bypassing the Kubernetes API server and scheduler. The kubelet watches a local directory (`/etc/kubernetes/manifests`) and creates or restarts the pods defined in those YAML files. Kubelet creates a read-only "Mirror Pod" on the API server so administrators can inspect them via `kubectl`, but they cannot be scaled, modified, or deleted via `kubectl`.

### How does node TLS bootstrap authentication work during `kubeadm join`?
1. The worker fetches the `cluster-info` ConfigMap from the API server and verifies its root CA certificate against the `--discovery-token-ca-cert-hash` (SHA256 thumbprint) to prevent Man-in-the-Middle attacks.
2. The worker authenticates using the shared bootstrap token (`system:bootstrappers` group) and submits a `CertificateSigningRequest` (CSR).
3. The `kube-controller-manager` CSR approving controller validates the request and issues a unique client certificate for the node (`system:node:<node-name>`).
4. The worker downloads the signed certificate into `/var/lib/kubelet/pki/kubelet-client-current.pem` and transitions to regular mTLS communication.

### Why do worker nodes initially report `NotReady` upon joining?
Kubelet registers the node with `Ready=False` because no Container Network Interface (CNI) is present. Kubelet checks `/etc/cni/net.d/` for a valid CNI configuration. Until a CNI like Calico installs its binary and configuration file, the container runtime network is uninitialized.

---

## 2. Networking & Traffic Routing Internals

### What are the architectural differences between Calico CNI and AWS VPC CNI?
- **AWS VPC CNI**: Assigns secondary private IP addresses directly from the AWS VPC subnet to each pod via Elastic Network Interfaces (ENIs). Pods consume limited VPC IP space and are subject to AWS instance ENI attachment limits (e.g., max 18 pods on a t3.medium).
- **Calico CNI**: Operates an independent pod IP pool (e.g. `192.168.0.0/16`) decoupled from the underlying VPC subnet. It routes traffic across nodes using an overlay (VXLAN or IP-in-IP) or native BGP routing, supporting thousands of pods without exhausting VPC subnets.

### Why must EC2 `source_dest_check` be disabled for overlay CNI traffic?
AWS EC2 hypervisors enforce strict Source/Destination IP checking on every virtual network interface. If an instance attempts to forward a packet where the source or destination IP does not match its assigned EC2 private IP (such as pod traffic originating from `192.168.x.x`), the hypervisor drops the packet. Disabling `source_dest_check` allows the EC2 VM to function as a network router for overlay pod traffic.

### How does MetalLB Layer 2 mode route traffic without an AWS ELB?
MetalLB assigns a private IP VIP from a designated pool to a `type: LoadBalancer` Service. MetalLB speaker pods run a leader election (via memberlist) to elect a single node to "own" that VIP. That node's speaker responds to ARP requests for the VIP with its own MAC address. Once packets reach the node, `kube-proxy` iptables rules distribute the traffic to backend pods across any node in the cluster.

### How does MetalLB handle node failover and ARP convergence?
The remaining MetalLB speaker pods detect node failure via heartbeat loss within seconds, elect a new leader node, and immediately broadcast a **Gratuitous ARP (GARP)** frame. This updates the ARP cache on switches and routers, shifting all incoming VIP traffic to the new healthy node with zero cloud API latency.

---

## 3. Storage & Resource Governance

### Why use `volumeBindingMode: WaitForFirstConsumer` for local storage?
With `volumeBindingMode: Immediate` (the default), the PersistentVolume is created immediately when the PVC is declared, binding to an arbitrary node's local disk before the pod is scheduled. If the pod has affinity, node selectors, or resource requirements that force it to run on a *different* node, the pod will fail to start (`volume node affinity conflict`). `WaitForFirstConsumer` delays PV binding until the scheduler selects the best node for the pod, ensuring the local volume is created on that exact node.

### CPU Requests vs. CPU Limits vs. Memory Limits: Linux Kernel Primitives
- **CPU Request**: Maps to CFS shares. Used by the scheduler for node placement. Guaranteed minimum compute allocation.
- **CPU Limit**: Maps to CFS Bandwidth Quota (`cpu.cfs_quota_us`). When exceeded, the process is **throttled** (clock cycles starved) but never terminated.
- **Memory Limit**: Maps to the cgroup memory limit (`memory.max`). When exceeded, the Linux kernel OOM Killer immediately kills the offending process with SIGKILL (Exit Code 137).

### Root cause analysis of container Exit Code 137 (OOMKilled)
In Linux/Unix, an exit code above 128 indicates termination by a signal: `128 + Signal Number`. Signal 9 is `SIGKILL`. `128 + 9 = 137`. In Kubernetes, this indicates an **OOMKilled** event where the Linux kernel memory controller terminated the container for exceeding its configured cgroup memory limit.

---

## 4. Day-2 Operations & Disaster Recovery

### What is the operational difference between `cordon` and `drain`?
- `kubectl cordon`: Marks the node as unschedulable (`node.kubernetes.io/unschedulable:NoSchedule`). Existing pods continue running; no new pods can be placed on it.
- `kubectl drain`: Cordons the node and then evicts all existing pods gracefully using the Eviction API, respecting `PodDisruptionBudgets` and `terminationGracePeriodSeconds`.

### Why are `--ignore-daemonsets` and `--delete-emptydir-data` required for node drains?
- **DaemonSets**: Because DaemonSet pods run on every node by definition, evicting them would cause the DaemonSet controller to immediately recreate them on that same node.
- **EmptyDir Data**: Pods using `emptyDir` store ephemeral data on the node's local disk. Evicting the pod permanently deletes this data. Kubernetes forces explicit administrator confirmation via `--delete-emptydir-data`.

### What is the node failure detection and eviction timeline?
1. Kubelet stops updating its Node Lease in `kube-node-lease`.
2. After `--node-monitor-grace-period` (default 40s), the controller-manager marks the node `NotReady` / `Unknown` and applies the `node.kubernetes.io/unreachable:NoExecute` taint.
3. Pods without custom tolerations tolerate this taint for 300 seconds (`tolerationSeconds: 300`).
4. At the 5-minute mark, the eviction controller marks pods on the dead node as `Terminating` and schedules replacement pods onto healthy surviving nodes.

### How does etcd maintain data consistency via Raft consensus?
Etcd uses the **Raft consensus algorithm**. It elects a single leader that handles all write operations and replicates log entries across follower nodes. A write is committed only after a **quorum** (majority) of nodes confirm: `Quorum = floor(N/2) + 1`. For example, a 3-node cluster can tolerate 1 failure; a 5-node cluster can tolerate 2 failures.

### Why does etcd require an odd number of cluster members?
Adding an even member increases failure vulnerability without increasing fault tolerance. A 3-node cluster requires 2 nodes for quorum (tolerates 1 failure). A 4-node cluster requires 3 nodes for quorum (still tolerates only 1 failure), but introduces an extra node that could fail and increase split-brain risk.

### What is the authoritative procedure for etcd snapshot creation and point-in-time restoration?
1. **Backup**: Run `etcdctl snapshot save <path>` supplying the etcd CA certificate (`--cacert`), server cert (`--cert`), and private key (`--key`) for mTLS authentication.
2. **Verify**: Check integrity via `etcdctl snapshot status <path>`.
3. **Restore**:
   - Temporarily stop control plane static pods by moving manifests from `/etc/kubernetes/manifests/`.
   - Run `etcdctl snapshot restore <snapshot.db> --data-dir=<new-path>`.
   - Update `etcd.yaml` static pod manifest `hostPath` to point to `<new-path>`.
   - Move manifests back to `/etc/kubernetes/manifests/`. Kubelet automatically restarts etcd and the API server.

### Systematic troubleshooting runbook for `CrashLoopBackOff` pods
1. Run `kubectl describe pod <pod>`: Inspect `Last State`, `Exit Code`, `Reason`, and the `Events` section.
2. Check current logs: `kubectl logs <pod>`.
3. Check previous crashed container logs: `kubectl logs <pod> --previous`.
4. If the pod restarts too quickly to check logs, override the entrypoint with `command: ["sleep", "3600"]` to keep it alive and exec into the container.

### Diagnosing NetworkPolicy connectivity failures
1. Check application logs for connection timeouts (`dial tcp ... i/o timeout`).
2. Verify target pods are healthy and endpoints exist: `kubectl get endpoints <service>`.
3. Check active network policies: `kubectl get netpol -n <namespace>`. Remember that if *any* NetworkPolicy selects a pod, that pod enters a "default deny" state for unlisted ingress/egress.
4. Launch an ephemeral debug container with `nc` or `curl` (`kubectl exec ... -- nc -zv <target> <port> -w 2`) to verify which port or protocol is being dropped.
5. Update the NetworkPolicy to include matching `podSelector` and port declarations.

### Zero-downtime rolling update mechanics and surge allocation
The Deployment controller manages two ReplicaSets simultaneously. Using `maxSurge` (how many extra pods can be created) and `maxUnavailable` (how many pods can be taken down), it launches new pods first. Traffic is only shifted to new pods once their **Readiness Probes** pass. If a new version fails readiness or crashes, the rollout halts, preserving existing healthy replicas.

### Architectural difference: Liveness Probes vs. Readiness Probes
- **Liveness Probe**: Determines if the container needs to be restarted. If it fails, kubelet kills the container and initiates the restart policy.
- **Readiness Probe**: Determines if the container is ready to accept user traffic. If it fails, the pod is removed from Service `Endpoints` / `EndpointSlices`. The container is **not** killed.

### Prometheus `up == 0` telemetry and cluster observability
The `up` metric is automatically recorded by Prometheus for every scrape target. `up{job="node-exporter"} == 0` signifies that the physical node or host daemon has stopped responding to HTTP scrapes. Combined with `kube_node_status_condition{condition="Ready",status="true"} == 0`, it allows platform engineers to detect hypervisor failures or dead nodes before application evictions begin.

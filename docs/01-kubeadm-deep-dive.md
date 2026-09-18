# Kubeadm Bootstrap Deep Dive & Interview Reference Guide

This document breaks down every certificate, component, static pod, and TLS flow created during `kubeadm init` and `kubeadm join`. You will be able to explain the entire control plane anatomy in senior Kubernetes/DevOps engineering interviews.

---

## 1. The Kubernetes PKI (Public Key Infrastructure)

When you run `kubeadm init`, Kubernetes creates an enterprise-grade x509 PKI under `/etc/kubernetes/pki`. There are **three independent Certificate Authorities (CAs)**, plus a dedicated keypair for ServiceAccount signing.

```
/etc/kubernetes/pki/
├── ca.crt & ca.key                        <-- Primary Kubernetes Cluster CA
├── apiserver.crt & apiserver.key          <-- API Server serving cert (matches certSANs)
├── apiserver-kubelet-client.crt & key     <-- API Server to Kubelet authentication
├── front-proxy-ca.crt & key               <-- Aggregation Layer CA
├── front-proxy-client.crt & key           <-- For aggregated API servers (e.g. metrics-server)
├── sa.pub & sa.key                        <-- RSA keypair for signing ServiceAccount JWTs
└── etcd/
    ├── ca.crt & ca.key                    <-- Dedicated etcd CA
    ├── server.crt & server.key            <-- etcd server TLS cert
    ├── peer.crt & peer.key                <-- etcd inter-peer replication TLS cert
    ├── healthcheck-client.crt & key       <-- etcd liveness probe cert
    └── apiserver-etcd-client.crt & key    <-- API Server mutual TLS authentication to etcd
```

### Deep Explanation of Each Certificate Authority:
1. **Primary Cluster CA (`ca.crt`, `ca.key`)**:
   - The root trust anchor for the entire cluster.
   - Signs the `apiserver.crt` and client certificates used by `kube-controller-manager`, `kube-scheduler`, `admin.conf`, and `kubelet.conf`.
   - Every pod in the cluster mounts `ca.crt` at `/var/run/secrets/kubernetes.io/serviceaccount/ca.crt` to verify that the Kubernetes API server is genuine.

2. **Etcd CA (`etcd/ca.crt`, `etcd/ca.key`)**:
   - Kept cryptographically separate from the cluster CA.
   - Etcd contains the entire declarative state of the cluster (including all Secrets). To prevent a compromised node or API client from talking directly to etcd, etcd requires mutual TLS (mTLS) with its own isolated CA.
   - Only `kube-apiserver` possesses a valid client certificate (`apiserver-etcd-client.crt`) signed by this CA.

3. **Front-Proxy CA (`front-proxy-ca.crt`, `front-proxy-ca.key`)**:
   - Used for the **Kubernetes API Aggregation Layer**.
   - When you install aggregated API extensions like `metrics-server` or Prometheus Adapter, the client connects to `kube-apiserver`, and `kube-apiserver` acts as a reverse proxy, authenticating to the extension using `front-proxy-client.crt`.

4. **ServiceAccount Token Keypair (`sa.key`, `sa.pub`)**:
   - These are **not** x509 certificates; they are raw 2048-bit RSA keys.
   - `sa.key` is used by the `kube-controller-manager` (Token Controller) to cryptographically sign JWT bearer tokens injected into pods.
   - `sa.pub` is passed to `kube-apiserver` (`--service-account-key-file`) to verify the signature of JWT tokens in incoming HTTP requests (`Authorization: Bearer <token>`).

---

## 2. Static Pod Manifests (`/etc/kubernetes/manifests`)

How do control plane components start before Kubernetes itself exists? The answer is **Static Pods**.

### How Static Pods Work:
- The Linux systemd service `kubelet` is started first.
- Kubelet scans the directory `/etc/kubernetes/manifests` every 20 seconds.
- Whenever a pod YAML manifest appears in this directory, kubelet launches it directly via the container runtime (`containerd`), completely bypassing the Kubernetes API server and scheduler.
- Once the `kube-apiserver` container starts up, kubelet creates a **Mirror Pod** in the API server so administrators can see control plane pods via `kubectl get pods -n kube-system`.

### Component Analysis:

| Component | Manifest File | Port | Role & Architecture |
|---|---|---|---|
| **kube-apiserver** | `kube-apiserver.yaml` | 6443 | Stateless REST API gateway, authentication, authorization (RBAC), admission webhooks, writes directly to etcd. |
| **etcd** | `etcd.yaml` | 2379, 2380 | Distributed, consistent key-value store using Raft consensus algorithm. Port 2379 is for client queries; port 2380 is for peer-to-peer raft replication. |
| **kube-controller-manager** | `kube-controller-manager.yaml` | 10257 | Control loops engine (Node Lifecycle Controller, ReplicaSet Controller, ServiceAccount Controller, EndpointSlice Controller). Reconciles actual state to desired state. |
| **kube-scheduler** | `kube-scheduler.yaml` | 10259 | Evaluates unscheduled pods through filtering (predicates) and scoring (priorities) to assign pods to healthy worker nodes (`spec.nodeName`). |

---

## 3. Kubeconfig Credentials (`/etc/kubernetes/*.conf`)

Kubeadm generates 4 pre-configured kubeconfigs:
1. `admin.conf`: Bound to the `system:masters` group in its client certificate subject (`O=system:masters, CN=kubernetes-admin`). By default, Kubernetes RBAC has a ClusterRoleBinding `cluster-admin` bound to `system:masters` giving unrestricted superuser access.
2. `kubelet.conf`: Used by kubelet to report node status, heartbeat leases (`system:nodes` group).
3. `controller-manager.conf`: Used by controller-manager to watch and mutate resources.
4. `scheduler.conf`: Used by scheduler to watch unscheduled pods and bind them to nodes.

---

## 4. The Worker Node TLS Bootstrap Architecture

When a worker joins via `kubeadm join 10.0.1.10:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>`:

```
[Worker Node]                                                  [Control Plane]
     │                                                               │
     │  1. GET /api/v1/namespaces/kube-system/configmaps/cluster-info │
     ├──────────────────────────────────────────────────────────────>│
     │     (Verifies CA cert using sha256 discovery-token hash)      │
     │                                                               │
     │  2. Authenticate using Bootstrap Token (temporary credentials) │
     │     POST /apis/certificates.k8s.io/v1/certificatesigningrequests│
     ├──────────────────────────────────────────────────────────────>│
     │                                                               │
     │                                                               │ 3. CSR Auto-Approval
     │                                                               │    Controller validates
     │                                                               │    system:bootstrappers
     │                                                               │
     │  4. Downloads signed Client Certificate                       │
     │<──────────────────────────────────────────────────────────────┤
     │     Stored in /var/lib/kubelet/pki/kubelet-client-current.pem │
     │                                                               │
     │  5. Node registers itself: POST /api/v1/nodes                 │
     ├──────────────────────────────────────────────────────────────>│
```

### Interview Explanation Points:
- **Why is `--discovery-token-ca-cert-hash` necessary?** Without this, a worker node could be subjected to a Man-in-the-Middle (MITM) attack where a rogue machine responds with an attacker CA. The SHA256 thumbprint verifies that the CA downloaded from `cluster-info` ConfigMap is authentic before exchanging any secrets.
- **Why do worker nodes show `NotReady` immediately after joining?** Kubelet starts and registers, but reports `Ready=False` with `KubeletNotReady: container runtime network not ready: NetworkReady=false reason:NetworkPluginNotReady message:Network plugin returns error: cni plugin not initialized`. It remains `NotReady` until a CNI plugin (Calico) installs network configuration files into `/etc/cni/net.d/`.

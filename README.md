# Production Self-Managed Kubernetes Platform on AWS EC2 (Bare-Metal Emulation)

[![Kubernetes Version](https://img.shields.io/badge/kubernetes-v1.30.0-blue.svg?logo=kubernetes)](https://kubernetes.io/)
[![Bootstrap](https://img.shields.io/badge/bootstrap-kubeadm-326ce5.svg?logo=kubernetes)](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/)
[![CNI](https://img.shields.io/badge/CNI-Calico%20v3.28-orange.svg)](https://projectcalico.docs.tigera.io/)
[![LoadBalancer](https://img.shields.io/badge/LoadBalancer-MetalLB%20L2-yellow.svg)](https://metallb.universe.tf/)
[![Storage](https://img.shields.io/badge/Storage-Local%20Path%20Provisioner-green.svg)](https://github.com/rancher/local-path-provisioner)
[![AWS Services](https://img.shields.io/badge/AWS-EC2%20Only%20(No%20EKS)-ff9900.svg?logo=amazon-aws)](https://aws.amazon.com/ec2/)

A portfolio-grade, production-engineered self-managed Kubernetes platform deployed on raw AWS EC2 Linux VMs using `kubeadm`. 

> [!IMPORTANT]
> **Core Architectural Tenet: Zero-Cloud-Managed Dependencies**
> **This platform does NOT rely on AWS EKS or cloud-managed control planes.**
> AWS EC2 is treated strictly as bare-metal compute infrastructure. The control plane PKI, etcd Raft quorum, static pod manifests, Calico overlay routing, MetalLB Layer 2 ARP load balancing, and dynamic local persistent storage are all self-managed and configured from the operating system up.

---

## Table of Contents
1. [⚡ Quickstart Guide (Deploy in 5 Steps)](#-quickstart-guide-deploy-in-5-steps)
2. [Architecture & Component Topology](#architecture--component-topology)
3. [Why Self-Managed (kubeadm) vs. Cloud-Managed (EKS)?](#why-self-managed-kubeadm-vs-cloud-managed-eks)
4. [Repository Directory Structure](#repository-directory-structure)
5. [Build Phase: Step-by-Step Platform Setup](#build-phase-step-by-step-platform-setup)
   - [Step 1: Infrastructure as Code (Terraform & Security Groups)](#step-1-infrastructure-as-code-terraform--security-groups)
   - [Step 2: OS Prep, Containerd & Kubeadm Control Plane Bootstrap](#step-2-os-prep-containerd--kubeadm-control-plane-bootstrap)
   - [Step 3: Calico CNI & Cross-Node Connectivity](#step-3-calico-cni--cross-node-connectivity)
   - [Step 4: MetalLB On-Prem Load Balancing & Ingress-NGINX](#step-4-metallb-on-prem-load-balancing--ingress-nginx)
   - [Step 5: Self-Managed Persistent Storage & PostgreSQL StatefulSet](#step-5-self-managed-persistent-storage--postgresql-statefulset)
   - [Step 6: Google Online Boutique 11-Microservices Suite](#step-6-google-online-boutique-11-microservices-suite)
   - [Step 7: In-Cluster Container Registry & GitHub Actions CI/CD](#step-7-in-cluster-container-registry--github-actions-cicd)
   - [Step 8: Observability Stack (Prometheus, Alertmanager, Grafana)](#step-8-observability-stack-prometheus-alertmanager-grafana)
5. [Day-2 Operations Evidence Log (Production Incidents & Drills)](#day-2-operations-evidence-log)
   - [Drill 9: Worker Node Failure & Pod Eviction Timing](#drill-9-worker-node-failure--pod-eviction-timing)
   - [Drill 10: Node Cordon, Eviction Drain & PodDisruptionBudgets](#drill-10-node-cordon-eviction-drain--poddisruptionbudgets)
   - [Drill 11: Zero-Downtime Rolling Update & Instant Disaster Rollback](#drill-11-zero-downtime-rolling-update--instant-disaster-rollback)
   - [Drill 12: Break-Fix Incident (NetworkPolicy Isolation Debugging)](#drill-12-break-fix-incident-networkpolicy-isolation-debugging)
   - [Drill 13: Etcd Disaster Recovery (Snapshot & Point-in-Time Restore)](#drill-13-etcd-disaster-recovery-snapshot--point-in-time-restore)
   - [Drill 14: Resource Management, Kernel OOMKill (Exit 137) & CPU Throttling](#drill-14-resource-management-kernel-oomkill-exit-137--cpu-throttling)
6. [AWS EC2 Cost Optimization & Power Management](#aws-ec2-cost-optimization--power-management)
7. [Deep-Dive Technical Documentation](#deep-dive-technical-documentation)

---

## Architecture & Component Topology

```
                                  INTERNET / WORKSTATION
                                             │
                                             ▼
                               [ AWS VPC: 10.0.0.0/16 ]
                                             │
                                             ▼
                       ┌───────────────────────────────────────────┐
                       │  MetalLB L2 VIP (10.0.1.200) (ARP Broadcast)
                       └─────────────────────┬─────────────────────┘
                                             │
                                             ▼
                               [ Ingress-NGINX Controller ]
                                             │
                   ┌─────────────────────────┼─────────────────────────┐
                   ▼                         ▼                         ▼
         [Google Online Boutique]     [PostgreSQL DB]       [Prometheus / Grafana]
          (11 Microservices)          (StatefulSet)            (Metrics & Alerts)
                   │                         │                         │
 ══════════════════╪═════════════════════════╪═════════════════════════╪═════════════════
                   │   Calico CNI Overlay (Pod CIDR: 192.168.0.0/16)   │
 ══════════════════╪═════════════════════════╪═════════════════════════╪═════════════════
                   │                         │                         │
         ┌─────────┴─────────┐     ┌─────────┴─────────┐     ┌─────────┴─────────┐
         │      k8s-cp1      │     │    k8s-worker1    │     │    k8s-worker2    │
         │   (10.0.1.10)     │     │   (10.0.1.20)     │     │   (10.0.1.21)     │
         ├───────────────────┤     ├───────────────────┤     ├───────────────────┤
         │ • kube-apiserver  │     │ • kubelet         │     │ • kubelet         │
         │ • etcd (mTLS Raft)│     │ • containerd      │     │ • containerd      │
         │ • kube-scheduler  │     │ • MetalLB Speaker │     │ • MetalLB Speaker │
         │ • controller-mgr  │     │ • Calico Node     │     │ • Calico Node     │
         │ • Registry:30500  │     │ • Local Storage   │     │ • Local Storage   │
         └───────────────────┘     └───────────────────┘     └───────────────────┘
```

---

## Why Self-Managed (kubeadm) vs. Cloud-Managed (EKS)?

| Architectural Dimension | Managed Kubernetes (AWS EKS) | Our Self-Managed Cluster (kubeadm on EC2) |
|---|---|---|
| **Control Plane Access** | Black-box AWS-managed service ($73/month base fee). No SSH access to master nodes. | 100% owned and managed directly on `k8s-cp1`. Direct access to static pods and logs. |
| **PKI & Certificates** | AWS automatically generates and rotates certificates. Hidden from administrator. | Complete control over x509 PKI (`/etc/kubernetes/pki`), root CAs, etcd mTLS, and ServiceAccount keys. |
| **Etcd Management** | Fully abstracted by AWS. No access to etcd snapshots or Raft quorum. | Directly administer etcd key-value store, perform point-in-time snapshot restores, and manage compaction. |
| **Pod Networking** | AWS VPC CNI assigns secondary VPC IPs to pods; hits strict EC2 ENI attachment limits. | Calico CNI with VXLAN overlay decouples pod IP space (`192.168.0.0/16`) from VPC subnets. |
| **Load Balancing** | Cloud-controller-manager provisions AWS NLBs/ALBs ($16–$22/month each). | MetalLB runs in-cluster, handling Layer 2 ARP broadcasts for private VIPs ($0.00 cloud fees). |
| **Persistent Storage** | AWS EBS CSI driver creates dynamic EBS volumes via AWS Cloud APIs. | Rancher Local Path Provisioner dynamically manages hostPath disks, emulating on-prem DAS/SAN. |

---

## ⚡ Quickstart Guide (Deploy in 5 Steps)

Follow this quickstart to deploy the entire production self-managed cluster on AWS in under 15 minutes:

### 1. Prerequisites
- AWS CLI configured (`aws configure`) with credentials for `us-east-1` (or your target region).
- Terraform v1.5+ installed.
- An existing AWS EC2 Key Pair (e.g., `KEY-PAIR-VIRGINIA.pem`).

### 2. Provision Infrastructure (Terraform)
```bash
git clone https://github.com/Pruthviraj-333/self-managed-k8s-platform.git
cd self-managed-k8s-platform/terraform
cp terraform.tfvars.example terraform.tfvars
# Update key_name and admin_ip in terraform.tfvars
terraform init
terraform apply -auto-approve
```
*Outputs provide the static private IPs and assigned public IPs for `k8s-cp1`, `k8s-worker1`, and `k8s-worker2`.*

### 3. Bootstrap OS & Control Plane (Kubeadm)
SSH into the nodes using your key pair:
```bash
# On ALL 3 nodes (Control plane & workers):
bash kubeadm/00-prep-node.sh
bash kubeadm/01-install-containerd.sh
bash kubeadm/02-install-kubernetes.sh

# On Control Plane (k8s-cp1) only:
bash kubeadm/03-init-control-plane.sh

# On Worker Nodes (k8s-worker1, k8s-worker2):
sudo kubeadm join 10.0.1.10:6443 --token <TOKEN> --discovery-token-ca-cert-hash sha256:<HASH>
```

### 4. Deploy Core Networking, Storage & Load Balancing
From the control plane (`k8s-cp1`):
```bash
# 1. Calico CNI (Pod overlay network 192.168.0.0/16)
kubectl apply -f cni/calico/01-tigera-operator.yaml
kubectl apply -f cni/calico/02-custom-resources.yaml

# 2. MetalLB Layer 2 Load Balancer & Ingress-NGINX
bash metallb/00-install-metallb.sh
bash ingress/00-install-ingress.sh

# 3. Dynamic Local Path Storage & PostgreSQL StatefulSet
bash storage/00-install-local-path.sh
bash storage/verify-storage.sh
```

### 5. Launch Workloads & Observability Stack
```bash
# 1. Google Online Boutique (11 Microservices Suite)
bash workloads/online-boutique/deploy-boutique.sh

# 2. Prometheus, Alertmanager & Grafana Monitoring Stack
bash monitoring/deploy-monitoring.sh
kubectl apply -f monitoring/06-grafana-dashboards.yaml
```

### 🌐 Live Service Access:
- **Online Boutique Storefront**: `http://<Node-Public-IP>:32362`
- **Grafana Cluster Dashboard**: `http://<Node-Public-IP>:32000` *(User: `admin` / Password: `admin_password`)*
- **Prometheus Metrics Console**: `http://<Node-Public-IP>:30090`

### ⏸️ Power Saving & Cost Management:
When finished testing, pause compute billing immediately:
```powershell
.\scripts\cluster-power.ps1 stop     # Windows PowerShell
# or: bash scripts/cluster-power.sh stop  # Linux / macOS
```

---

## Repository Directory Structure

```
.
├── README.md                              # Master Architecture & Operational Guide
├── COSTS.md                               # AWS Budget, pricing calculator, and shutdown guide
├── terraform/                             # Raw EC2 & Network Infrastructure
│   ├── main.tf                            # VPC, Subnet, Internet Gateway, Route Tables
│   ├── security_groups.tf                 # Control Plane & Worker port matrices
│   ├── ec2.tf                             # 1 CP + 2 Worker EC2 instances (source_dest_check=false)
│   ├── variables.tf                       # Instance types, regions, admin CIDR
│   ├── outputs.tf                         # IPs and pre-formatted SSH connection strings
│   └── terraform.tfvars.example           # Example configuration
├── kubeadm/                               # Cluster Bootstrap Engine
│   ├── 00-prep-node.sh                    # Swapoff, overlay, br_netfilter, sysctl
│   ├── 01-install-containerd.sh           # containerd with SystemdCgroup=true
│   ├── 02-install-kubernetes.sh           # kubeadm, kubelet, kubectl package pinning
│   ├── 03-init-control-plane.sh           # Control plane init & PKI inspection
│   ├── 04-join-workers.sh                 # TLS bootstrap discovery token worker join
│   └── kubeadm-config.yaml                # Declarative ClusterConfiguration & certSANs
├── cni/calico/                            # Container Network Interface
│   ├── 01-tigera-operator.yaml            # Tigera operator deployment
│   ├── 02-custom-resources.yaml          # Installation CR (CIDR: 192.168.0.0/16)
│   └── verify-connectivity.sh             # Cross-node pod-to-pod ping, curl & DNS test
├── metallb/                               # Bare-Metal Load Balancer
│   ├── 00-install-metallb.sh              # Native controller and speaker deployment
│   ├── 01-ipaddresspool.yaml              # Private VPC subnet IP pool (10.0.1.200-210)
│   ├── 02-l2advertisement.yaml            # Layer 2 ARP advertisement
│   └── verify-metallb.sh                  # VIP allocation & ARP probe script
├── ingress/                               # Ingress Gateway
│   ├── 00-install-ingress.sh              # Ingress-NGINX bare-metal deployment
│   └── verify-ingress.sh                  # Host-header HTTP routing test script
├── storage/                               # Self-Managed Persistent Storage
│   ├── 00-install-local-path.sh           # Local Path Provisioner installer
│   ├── local-path-storage.yaml            # Dynamic hostPath provisioner & StorageClass
│   ├── verify-storage.sh                  # Crash & persistence test script
│   └── postgres-statefulset/              # Stateful Database Workload
│       ├── postgres-secret-svc.yaml       # Credentials & Headless Service
│       └── postgres-statefulset.yaml      # StatefulSet with 2Gi dynamic PVC
├── workloads/online-boutique/             # 11-Microservice Cloud-Native Demo
│   ├── 00-namespace-ingress.yaml          # Namespace & Ingress routing
│   ├── 01-online-boutique.yaml            # Tuned Deployments & Services
│   └── deploy-boutique.sh                 # Automated deploy & rollout verification
├── registry/                              # In-Cluster Container Registry & CI/CD
│   ├── docker-registry.yaml               # registry:2 deployment backed by local PVC
│   ├── configure-containerd-registry.sh   # Node CRI trust configuration
│   └── verify-registry.sh                 # Image tag, push, and deployment test
├── .github/workflows/                     # Continuous Integration & Delivery
│   └── ci-cd.yaml                         # Automated build, test, push, and rollout
├── monitoring/                            # Observability Stack
│   ├── 01-node-exporter.yaml              # Host-level hardware metrics DaemonSet
│   ├── 02-prometheus-alert-rules.yaml     # ConfigMap with NodeDown & HighMemory rules
│   ├── 03-prometheus-deploy.yaml          # Prometheus server with persistent TSDB storage
│   ├── 04-alertmanager.yaml               # Alert routing & notification engine
│   ├── 05-grafana.yaml                    # Dashboards & auto-provisioned Prometheus source
│   ├── 06-grafana-dashboards.yaml         # Kubernetes Cluster Overview interactive dashboard
│   └── deploy-monitoring.sh               # Monitoring stack setup script
├── day2-operations/                       # Production Drill Runbooks & Evidence
│   ├── 01-node-failure-recovery/          # Node loss, lease expiry, pod eviction timing
│   ├── 02-cordon-drain/                   # Safe maintenance, PodDisruptionBudgets, uncordon
│   ├── 03-rolling-update-rollback/        # Phased rollout, ImagePullBackOff, instant rollback
│   ├── 04-break-fix-drill/                # NetworkPolicy outage diagnosis with kubectl
│   ├── 05-etcd-backup-restore/            # etcdctl mTLS snapshot & point-in-time restore
│   └── 06-resource-limits-oom/            # cgroup limits, OOMKill (Exit 137), CPU throttling
├── evidence/                              # Production Execution Logs & Visual Proofs
│   ├── 01..15-*.log                       # Raw terminal output logs from all 15 build steps & drills
│   ├── Screenshot 2026-09-18 170204.png   # AWS EC2 Console verification (3 nodes running)
│   ├── Screenshot 2026-09-18 173458.png   # Live Grafana cluster overview dashboard
│   ├── Screenshot 2026-09-18 173513.png   # Live Grafana disk & network throughput telemetry
│   ├── Screenshot 2026-09-18 173527.png   # Google Online Boutique storefront
│   ├── Screenshot 2026-09-18 173538.png   # Online Boutique product details
│   └── Screenshot 2026-09-18 173558.png   # Online Boutique shopping cart & checkout flow
├── scripts/                               # Management Utilities
│   ├── cluster-power.sh                   # One-command AWS power-off/power-on cost saver (Bash)
│   └── cluster-power.ps1                  # Native Windows PowerShell power-off/power-on utility
└── docs/                                  # Technical Architecture & Internals Deep Dives
    ├── 01-kubeadm-deep-dive.md            # PKI certificates, static pods, bootstrap token
    ├── 02-networking-deep-dive.md         # Calico overlay vs VPC CNI, MetalLB L2 ARP
    └── 03-architecture-and-internals-faq.md # Linux kernel primitives, control plane mechanics & operational FAQ
```

---

## Build Phase: Step-by-Step Platform Setup

### Step 1: Infrastructure as Code (Terraform & Security Groups)
We provision a dedicated AWS VPC (`10.0.0.0/16`) and 3 raw Ubuntu 22.04 LTS EC2 instances (`c7i-flex.large` / `t3.medium`, 2 vCPU, 4GB RAM) with static private IPs:
- `k8s-cp1`: `10.0.1.10`
- `k8s-worker1`: `10.0.1.20`
- `k8s-worker2`: `10.0.1.21`

#### Live AWS Infrastructure Proof (AWS EC2 Console):
*Raw Terminal Log*: [`evidence/01-cluster-nodes-initial.log`](file:///d:/self-managed-k8s-ec2/evidence/01-cluster-nodes-initial.log)

![AWS EC2 Console - 3 Active Kubernetes Instances](evidence/Screenshot%202026-09-18%20170204.png)
*Figure 1: AWS Management Console showing all 3 EC2 nodes (`k8s-cp1`, `k8s-worker1`, `k8s-worker2`) in healthy `Running` state (3/3 checks passed) with live CPU & Network telemetry.*

#### Critical Networking Port Matrix:
The security group [`terraform/security_groups.tf`](file:///d:/self-managed-k8s-ec2/terraform/security_groups.tf) enforces exact Kubernetes port boundaries:
- **Port 6443**: Kubernetes API Server (Worker nodes and Admin workstation).
- **Ports 2379-2380**: Etcd server client and peer communication (Control Plane internal only).
- **Port 10250**: Kubelet API (Control plane to workers, cAdvisor metrics).
- **Port 10259 / 10257**: Kube-scheduler and kube-controller-manager.
- **Port 4789 (UDP) / IP Protocol 4**: Calico VXLAN / IP-in-IP cross-node overlay traffic.
- **Ports 80 / 443**: Ingress HTTP/HTTPS traffic to MetalLB VIP.
- **`source_dest_check = false`**: Enabled on all EC2 instances to allow the Linux kernel to forward routed pod packets across network interfaces without AWS hypervisor packet drops.

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform apply -auto-approve
```

---

### Step 2: OS Prep, Containerd & Kubeadm Control Plane Bootstrap

On **ALL 3 nodes** (Control plane and workers), run:
```bash
# 1. Disable swap, load kernel modules (overlay, br_netfilter), set sysctl ip_forward
bash kubeadm/00-prep-node.sh

# 2. Install containerd and configure SystemdCgroup = true
bash kubeadm/01-install-containerd.sh

# 3. Install kubelet, kubeadm, kubectl and pin versions
bash kubeadm/02-install-kubernetes.sh
```

On **Control Plane (`k8s-cp1`)**, bootstrap the cluster:
```bash
bash kubeadm/03-init-control-plane.sh
```
*What kubeadm sets up under the hood*:
- **PKI Certificates** in `/etc/kubernetes/pki`: Generates independent CAs (`ca.crt`, `etcd/ca.crt`, `front-proxy-ca.crt`), server certs (`apiserver.crt`), and RSA ServiceAccount signing keys (`sa.key`, `sa.pub`).
- **Static Pod Manifests** in `/etc/kubernetes/manifests`: Generates `kube-apiserver.yaml`, `etcd.yaml`, `kube-controller-manager.yaml`, and `kube-scheduler.yaml`. Kubelet detects them directly on disk and launches them via containerd.
- **Kubeconfigs** in `/etc/kubernetes/`: Creates `admin.conf`, `kubelet.conf`, `controller-manager.conf`, and `scheduler.conf`.

On **Worker Nodes (`k8s-worker1`, `k8s-worker2`)**, join the cluster:
```bash
sudo kubeadm join 10.0.1.10:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

---

### Step 3: Calico CNI & Cross-Node Connectivity

By default, nodes stay in `NotReady` until a CNI is installed. We deploy Calico with pod network CIDR `192.168.0.0/16`:
```bash
kubectl apply -f cni/calico/01-tigera-operator.yaml
kubectl apply -f cni/calico/02-custom-resources.yaml
```
*Raw Logs*: [`evidence/02-nodes-ready-calico.log`](file:///d:/self-managed-k8s-ec2/evidence/02-nodes-ready-calico.log) | [`evidence/03-cni-cross-node-connectivity.log`](file:///d:/self-managed-k8s-ec2/evidence/03-cni-cross-node-connectivity.log)

Calico initializes an IPAM block from `192.168.0.0/16` and establishes cross-node encapsulation via `VXLANCrossSubnet`.

**Verify Cross-Node Routing**:
```bash
bash cni/calico/verify-connectivity.sh
```
*Output Evidence*:
```
>>> [3/5] Testing Cross-Node Pod-to-Pod ICMP Ping
64 bytes from 192.168.1.18: icmp_seq=1 ttl=64 time=0.812 ms
64 bytes from 192.168.1.18: icmp_seq=2 ttl=64 time=0.694 ms
>>> [4/5] Testing Cross-Node TCP HTTP Request (Port 5678)
Response from Worker 2 Pod: Calico Cross-Node Network OK
>>> SUCCESS: Pod-to-Pod overlay connectivity across physical nodes is working perfectly!
```

---

### Step 4: MetalLB On-Prem Load Balancing & Ingress-NGINX

On bare-metal, services of `type: LoadBalancer` remain `<pending>` because no cloud API exists. We install MetalLB to provide Layer 2 ARP load balancing using dedicated private IPs from our VPC subnet (`10.0.1.200 - 10.0.1.210`):
```bash
bash metallb/00-install-metallb.sh
bash ingress/00-install-ingress.sh
```
*Raw Logs*: [`evidence/04-metallb-ingress.log`](file:///d:/self-managed-k8s-ec2/evidence/04-metallb-ingress.log) | [`evidence/05-ingress-verification.log`](file:///d:/self-managed-k8s-ec2/evidence/05-ingress-verification.log)

MetalLB speaker pods elect a leader node via memberlist to respond to ARP requests for `10.0.1.200`. Ingress-NGINX binds to this VIP.

**Verify Ingress Routing**:
```bash
bash ingress/verify-ingress.sh
```
*Output Evidence*:
```
Ingress LoadBalancer IP: 10.0.1.200
HTTP Output: Ingress NGINX + MetalLB Working!
>>> SUCCESS: Ingress routing via MetalLB VIP verified!
```

---

### Step 5: Self-Managed Persistent Storage & PostgreSQL StatefulSet

Instead of relying on the AWS EBS CSI driver's managed API, we deploy **Rancher Local Path Provisioner** to dynamically provision volumes directly on the local disks of our EC2 worker nodes (`/opt/local-path-provisioner`):
```bash
bash storage/00-install-local-path.sh
```
We deploy a production PostgreSQL 15 StatefulSet and verify that state survives pod crashes:
```bash
bash storage/verify-storage.sh
```
*Raw Log*: [`evidence/06-storage-postgresql-persistence.log`](file:///d:/self-managed-k8s-ec2/evidence/06-storage-postgresql-persistence.log)

*Output Evidence*:
```
postgres-data-postgres-0   Bound    pvc-878ad12-b91c   2Gi   RWO   local-path   15s
>>> Simulating Pod Crash (Killing postgres-0)...
pod "postgres-0" deleted
Waiting for StatefulSet controller to recreate postgres-0...
>>> Querying PostgreSQL to Verify Data Persisted...
>>> SUCCESS: Persistent data survived pod termination!
>>> Local Path Provisioner has successfully stored database files on k8s-worker1 in /opt/local-path-provisioner/
```

---

### Step 6: Google Online Boutique 11-Microservices Suite

We deploy Google's cloud-native e-commerce microservices demo (Frontend, Cart, Catalog, Currency, Payment, Shipping, Email, Checkout, Recommendations, Ads, and Redis):
```bash
bash workloads/online-boutique/deploy-boutique.sh
```
*Raw Logs*: [`evidence/07-online-boutique-deployment.log`](file:///d:/self-managed-k8s-ec2/evidence/07-online-boutique-deployment.log) | [`evidence/07-online-boutique-http-response.log`](file:///d:/self-managed-k8s-ec2/evidence/07-online-boutique-http-response.log)

*Output Evidence*:
```
deployment.apps/frontend condition met
deployment.apps/cartservice condition met
deployment.apps/checkoutservice condition met
HTTP Status Code from Online Boutique Frontend: 200
>>> SUCCESS: Google Online Boutique is live and reachable via MetalLB + NGINX Ingress!
```

#### Live Workload Visual Proof (Google Online Boutique E-Commerce Suite):

##### 1. Storefront & Catalog View
![Google Online Boutique - Live Storefront](evidence/Screenshot%202026-09-18%20173527.png)
*Figure 2: Online Boutique live storefront served across worker nodes via NodePort 32362 and MetalLB Ingress (`10.0.1.200`), rendering product catalog and dynamic currency conversion.*

##### 2. Product Detail & RPC Microservice Interaction
![Google Online Boutique - Product Detail](evidence/Screenshot%202026-09-18%20173538.png)
*Figure 3: Product Detail view demonstrating gRPC communication between `frontend`, `productcatalogservice`, and `currencyservice` with quantity selection.*

##### 3. Stateful Cart & Checkout Pipeline
![Google Online Boutique - Shopping Cart and Checkout](evidence/Screenshot%202026-09-18%20173558.png)
*Figure 4: Active shopping cart and checkout order pipeline communicating with in-cluster `cartservice` (Redis backed), `shippingservice`, and `paymentservice`.*

---

### Step 7: In-Cluster Container Registry & GitHub Actions CI/CD

We deploy a self-hosted Docker registry (`registry:2`) backed by local persistent storage and expose it on NodePort `30500`:
```bash
kubectl apply -f registry/docker-registry.yaml
bash registry/configure-containerd-registry.sh
bash registry/verify-registry.sh
```
*Raw Log*: [`evidence/08-container-registry-ready.log`](file:///d:/self-managed-k8s-ec2/evidence/08-container-registry-ready.log)

We also provide a complete GitHub Actions CI/CD pipeline [`.github/workflows/ci-cd.yaml`](file:///d:/self-managed-k8s-ec2/.github/workflows/ci-cd.yaml) that builds code, pushes to `10.0.1.10:30500`, and triggers zero-downtime rollouts.

---

### Step 8: Observability Stack (Prometheus, Alertmanager, Grafana)

We deploy a lightweight, production-tuned observability stack with persistent TSDB storage and pre-provisioned interactive dashboards:
```bash
bash monitoring/deploy-monitoring.sh
kubectl apply -f monitoring/06-grafana-dashboards.yaml
```
*Raw Log*: [`evidence/09-monitoring-stack-ready.log`](file:///d:/self-managed-k8s-ec2/evidence/09-monitoring-stack-ready.log)

- **Node Exporter**: Collects host hardware metrics (CPU, memory, disk, network) on host network port 9100.
- **Prometheus**: Scrapes cAdvisor, Kubelet metrics, and node-exporter.
- **Alertmanager**: Pre-configured with operational alerts:
  - `KubernetesNodeDown`: Triggers if a node stops reporting metrics for > 1m.
  - `HighNodeMemoryUsage`: Triggers if host memory exceeds 85% for > 2m.
  - `ContainerOOMKilled`: Fires immediately when a container is killed by cgroup memory limits.
- **Grafana**: Accessible on port `32000` with the custom provisioned **Kubernetes Cluster Overview** dashboard.

#### Live Grafana Cluster Observability Proof:

##### 1. Cluster Health, Nodes, Pod Counts & Host Resource Metrics
![Grafana Kubernetes Cluster Overview](evidence/Screenshot%202026-09-18%20173458.png)
*Figure 5: Live Grafana Dashboard (`http://100.52.198.15:32000`) displaying 3 Active Cluster Nodes, 39 Running Pods, 0 Firing Operational Alerts, and real-time CPU & Memory utilization % across control plane and worker nodes.*

##### 2. Host Node Disk I/O Throughput & Network Telemetry
![Grafana Host Telemetry & Disk Throughput](evidence/Screenshot%202026-09-18%20173513.png)
*Figure 6: Granular host node telemetry from Prometheus Node Exporter tracking real-time Disk I/O Write throughput (kB/sec) across all 3 nodes (`10.0.1.10`, `10.0.1.20`, `10.0.1.21`).*

---

## Day-2 Operations Evidence Log

The following scenarios document real operational drills, failure simulations, and disaster recovery procedures executed on this cluster:

---

### Drill 9: Worker Node Failure & Pod Eviction Timing
*Runbook*: [`day2-operations/01-node-failure-recovery/scenario.md`](file:///d:/self-managed-k8s-ec2/day2-operations/01-node-failure-recovery/scenario.md)  
*Raw Terminal Log*: [`evidence/15-node-failure-eviction.log`](file:///d:/self-managed-k8s-ec2/evidence/15-node-failure-eviction.log)

**Objective**: Simulate sudden hardware/hypervisor loss of `k8s-worker2` and measure Kubernetes failover timing.
**Observed Execution Log**:
```bash
$ sudo shutdown -h now  # Executed on k8s-worker2

[T+42s] Kubelet lease expires. Node transitions to NotReady:
k8s-worker2   NotReady   worker   3h   v1.30.0

[T+45s] Taints injected by Node Lifecycle Controller:
Taints: node.kubernetes.io/unreachable:NoExecute

[T+345s] Pod tolerationSeconds (300s) expires. Eviction controller terminates dead pods:
frontend-69d6796987-9bc4x  1/1  Terminating        0  1h  k8s-worker2
frontend-69d6796987-zw9ql  0/1  ContainerCreating  0  2s  k8s-worker1

[T+355s] Replacement pods successfully Running on k8s-worker1. Total recovery: 5m 55s.
```

---

### Drill 10: Node Cordon, Eviction Drain & PodDisruptionBudgets
*Runbook*: [`day2-operations/02-cordon-drain/scenario.md`](file:///d:/self-managed-k8s-ec2/day2-operations/02-cordon-drain/scenario.md)  
*Raw Terminal Log*: [`evidence/10-cordon-drain-drill.log`](file:///d:/self-managed-k8s-ec2/evidence/10-cordon-drain-drill.log)

**Objective**: Safely drain `k8s-worker1` for kernel patching without violating service availability.
**Observed Execution Log**:
```bash
$ kubectl cordon k8s-worker1
node/k8s-worker1 cordoned (Status: Ready,SchedulingDisabled)

$ kubectl drain k8s-worker1 --ignore-daemonsets --delete-emptydir-data
evicting pod boutique/productcatalogservice-6c478c946f-5lknz
evicting pod boutique/frontend-69d6796987-zw9ql
evicting pod default/postgres-0
pod/frontend-69d6796987-zw9ql evicted
node/k8s-worker1 drained successfully

$ kubectl uncordon k8s-worker1
node/k8s-worker1 uncordoned
```

---

### Drill 11: Zero-Downtime Rolling Update & Instant Disaster Rollback
*Runbook*: [`day2-operations/03-rolling-update-rollback/scenario.md`](file:///d:/self-managed-k8s-ec2/day2-operations/03-rolling-update-rollback/scenario.md)  
*Raw Terminal Log*: [`evidence/11-rolling-upgrade-rollback.log`](file:///d:/self-managed-k8s-ec2/evidence/11-rolling-upgrade-rollback.log)

**Objective**: Inject a corrupted image tag into the frontend deployment, observe canary surge isolation, and roll back instantly.
**Observed Execution Log**:
```bash
$ kubectl set image deployment/frontend server=gcr.io/.../frontend:v99.9.9 -n boutique --record
deployment.apps/frontend image updated

$ kubectl get pods -n boutique -l app=frontend
frontend-69d6796987-9bc4x   1/1     Running            0   42m  <-- HEALTHY ACTIVE REPLICA
frontend-8686f56475-q7kzb   0/1     ImagePullBackOff   0   25s  <-- ISOLATED BROKEN REPLICA

$ kubectl rollout undo deployment/frontend -n boutique
deployment.apps/frontend rolled back
deployment "frontend" successfully rolled out
```

---

### Drill 12: Break-Fix Incident (NetworkPolicy Isolation Debugging)
*Runbook*: [`day2-operations/04-break-fix-drill/scenario.md`](file:///d:/self-managed-k8s-ec2/day2-operations/04-break-fix-drill/scenario.md)  
*Raw Terminal Log*: [`evidence/12-break-fix-networkpolicy-drill.log`](file:///d:/self-managed-k8s-ec2/evidence/12-break-fix-networkpolicy-drill.log)

**Objective**: Troubleshoot and resolve an outage where frontend throws `HTTP 500` due to a restrictive NetworkPolicy.
**Observed Execution Log**:
```bash
$ curl -I -H "Host: boutique.k8s.local" "http://10.0.1.200/"
HTTP/1.1 500 Internal Server Error

$ kubectl logs -n boutique deployment/frontend --tail=2
rpc error: code = Unavailable desc = "transport: Error while dialing: dial tcp 10.96.14.82:3550: i/o timeout"

# Identified active policy dropping ingress packets:
$ kubectl get netpol -n boutique
NAME              POD-SELECTOR                AGE
isolate-catalog   app=productcatalogservice   3m

# Remediation applied:
$ kubectl apply -f day2-operations/04-break-fix-drill/network-policies.yaml
networkpolicy.networking.k8s.io/isolate-catalog configured

$ curl -I -H "Host: boutique.k8s.local" "http://10.0.1.200/"
HTTP/1.1 200 OK
```

---

### Drill 13: Etcd Disaster Recovery (Snapshot & Point-in-Time Restore)
*Runbook*: [`day2-operations/05-etcd-backup-restore/scenario.md`](file:///d:/self-managed-k8s-ec2/day2-operations/05-etcd-backup-restore/scenario.md)  
*Raw Terminal Log*: [`evidence/13-etcd-backup-restore.log`](file:///d:/self-managed-k8s-ec2/evidence/13-etcd-backup-restore.log)

**Objective**: Create an etcd mTLS snapshot, simulate catastrophic namespace deletion, and restore state from disk.
**Observed Execution Log**:
```bash
$ sudo ETCDCTL_API=3 etcdctl --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  snapshot save /var/lib/etcd-backup/snapshot.db
Snapshot saved at /var/lib/etcd-backup/snapshot.db

$ kubectl delete namespace disaster-recovery-test
namespace "disaster-recovery-test" deleted

# Stop static pods, restore snapshot to new data-dir, update etcd.yaml, and restart:
$ bash day2-operations/05-etcd-backup-restore/restore-etcd.sh /var/lib/etcd-backup/snapshot.db
Restoring snapshot to /var/lib/etcd-restored...
Cluster API Server is back online!

$ kubectl get ns disaster-recovery-test
NAME                     STATUS   AGE
disaster-recovery-test   Active   12m  <-- SUCCESSFULLY RESTORED!
```

---

### Drill 14: Resource Management, Kernel OOMKill (Exit 137) & CPU Throttling
*Runbook*: [`day2-operations/06-resource-limits-oom/scenario.md`](file:///d:/self-managed-k8s-ec2/day2-operations/06-resource-limits-oom/scenario.md)  
*Raw Terminal Log*: [`evidence/14-resource-limits-oomkill.log`](file:///d:/self-managed-k8s-ec2/evidence/14-resource-limits-oomkill.log)

**Objective**: Prove Linux cgroup memory limit enforcement and CFS CPU bandwidth throttling.
**Observed Execution Log**:
```bash
$ kubectl apply -f day2-operations/06-resource-limits-oom/resource-pods.yaml
pod/oom-demo-pod created

$ kubectl logs -f oom-demo-pod
Allocating 120MB in chunks against a 64Mi limit...
Allocated 10MB
...
Allocated 60MB
command terminated with exit code 137

$ kubectl describe pod oom-demo-pod | grep -E "(State|Reason|Exit Code)"
    State:          Terminated
      Reason:       OOMKilled
      Exit Code:    137
```

---

## AWS EC2 Cost Optimization & Power Management

Detailed cost breakdown available in [`COSTS.md`](file:///d:/self-managed-k8s-ec2/COSTS.md).

- **Hourly Running Cost**: ~$0.15/hour (~$3.60/day for 3 instances).
- **Idle Stopped Cost**: **$0.24/day** (EBS disk storage only; compute is billed at $0.00/hour).
- **Zero Cloud Load Balancer / NAT Gateway Fees**: MetalLB and direct IGW routing save >$54.00/month.

### Power Management Commands:
When you are done testing, turn off compute billing immediately. Both Bash and Windows PowerShell scripts are provided:

#### Windows PowerShell:
```powershell
# Check current power state of cluster nodes
.\scripts\cluster-power.ps1 status

# Power off instances (saves compute fees while retaining all cluster data)
.\scripts\cluster-power.ps1 stop

# Resume cluster instances when starting work
.\scripts\cluster-power.ps1 start
```

#### Linux / macOS Bash:
```bash
# Power off instances
bash scripts/cluster-power.sh stop

# Resume work later
bash scripts/cluster-power.sh start

# Permanent cluster deletion
cd terraform && terraform destroy -auto-approve
```

---

## Deep-Dive Technical Documentation

- **[01-kubeadm-deep-dive.md](file:///d:/self-managed-k8s-ec2/docs/01-kubeadm-deep-dive.md)**: Deep breakdown of x509 PKI certificates, static pods, and TLS bootstrap token mechanics.
- **[02-networking-deep-dive.md](file:///d:/self-managed-k8s-ec2/docs/02-networking-deep-dive.md)**: Technical comparison of Calico CNI overlay vs AWS VPC CNI, why `source_dest_check=false` is mandatory on EC2, and MetalLB Layer 2 ARP leader election.
- **[03-architecture-and-internals-faq.md](file:///d:/self-managed-k8s-ec2/docs/03-architecture-and-internals-faq.md)**: Authoritative technical reference covering low-level Linux kernel primitives (cgroups/sysctl), control plane mechanics, networking overlays, storage binding, and disaster recovery procedures.

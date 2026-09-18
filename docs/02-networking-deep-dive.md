# Networking Deep Dive: Calico CNI, Overlay vs. VPC CNI, and MetalLB L2 ARP

This guide explains the foundational networking principles implemented in this cluster, covering container networking, overlay encapsulation, routing boundaries, and bare-metal ingress.

---

## 1. Calico Overlay vs. AWS VPC CNI

### AWS VPC CNI (The EKS Way):
- In managed AWS EKS, the default CNI is `amazon-vpc-cni-k8s`.
- It allocates secondary private IP addresses directly from your AWS VPC subnet and assigns them to pods via Elastic Network Interfaces (ENIs).
- **Major Limitations**:
  1. **IP Exhaustion**: A small `/24` subnet can only run ~200 pods across the entire cluster before running out of VPC IPs.
  2. **ENI Limits per Instance Type**: A `t3.medium` can only attach 3 ENIs with 6 IPv4 addresses each (maximum 18 pods per node!).
  3. **Cloud Vendor Lock-In**: Pods are tightly coupled to AWS network primitives.

### Calico CNI (The On-Premises / Bare-Metal Way):
- Calico decouples pod networking entirely from the underlying cloud or physical network.
- Pods are assigned IPs from an isolated, private CIDR pool (e.g. `192.168.0.0/16`).
- **Encapsulation Options**:
  - **VXLAN (Virtual Extensible LAN)**: Wraps layer-2 Ethernet frames inside standard UDP packets (port 4789).
  - **IP-in-IP (Protocol 4)**: Wraps the original IP packet inside an outer IP packet destined for the target node.
- **Why We Chose VXLANCrossSubnet**:
  - If two nodes are on the same VPC subnet, Calico routes packets natively with zero encapsulation overhead!
  - If packets cross subnet boundaries, Calico encapsulates via VXLAN.

---

## 2. Why `source_dest_check = false` is Mandatory on AWS EC2

By default, the AWS EC2 hypervisor inspects every packet leaving or entering an instance's network interface:
- **Rule**: If the packet's source IP does not match the instance's private IP (e.g. `10.0.1.20`), or if the destination IP does not match, AWS **silently drops the packet at the hypervisor level**.
- In our self-managed cluster, pods have IPs from `192.168.0.0/16`. When Pod A on Worker 1 sends a packet to Pod B on Worker 2, the source IP is `192.168.1.15`.
- Unless `source_dest_check` is disabled in AWS EC2, the AWS hypervisor drops all pod-to-pod cross-node traffic!

---

## 3. MetalLB Layer 2 Mode: Bare-Metal Load Balancing Demystified

### The Cloud Problem on Bare-Metal:
In public cloud environments, creating a Service of `type: LoadBalancer` triggers the cloud-controller-manager to provision an AWS Network Load Balancer (NLB) or Application Load Balancer (ALB).
On bare-metal or raw VMs without a cloud-controller-manager, the `EXTERNAL-IP` field stays stuck in `<pending>` forever.

### How MetalLB Solves This via Layer 2 ARP:
1. MetalLB consists of two components:
   - **Controller**: Watches for Services of `type: LoadBalancer` and allocates an unused IP from our configured `IPAddressPool` (e.g. `10.0.1.200`).
   - **Speaker**: A DaemonSet running on every node.
2. For each assigned VIP, the speakers run a leader election (via memberlist). One worker node is elected as the "leader" for that VIP.
3. The leader node's speaker responds to **ARP (Address Resolution Protocol) requests** for that VIP on the local network (`eth0`).
4. When any machine on the network asks "Who has 10.0.1.200?", the leader node replies with its own MAC address (`aa:bb:cc:dd:ee:ff`).
5. Inbound traffic arrives at the leader node's `eth0`.
6. `kube-proxy` (via iptables rules) intercepts the packet and distributes it evenly across all matching backend pods across the cluster!

### Failover Behavior:
If the leader node crashes:
- Memberlist detects the node failure within 3-5 seconds.
- A surviving speaker node is elected leader.
- The new leader sends a **Gratuitous ARP (GARP)** broadcast frame to update the switch/router's ARP cache.
- Traffic shifts to the new node with zero human intervention.

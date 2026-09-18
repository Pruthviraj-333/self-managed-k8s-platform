#!/bin/bash
# =============================================================================
# 00-prep-node.sh: Operating System & Linux Kernel Preparation
# Must be executed on ALL nodes (Control Plane and Workers)
# =============================================================================
set -euo pipefail

echo "=========================================================="
echo ">>> [1/4] Disabling Linux Swap"
echo "=========================================================="
# WHY: The Kubernetes kubelet memory manager assumes 100% control over physical
# memory allocation. If swap is active, memory overcommitment can cause pods
# to exceed their assigned memory limits without being properly OOMKilled,
# causing unpredictable node degradation and performance instability.
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

echo "=========================================================="
echo ">>> [2/4] Loading Required Linux Kernel Modules"
echo "=========================================================="
# WHY:
# - overlay: Required by containerd for the overlayfs storage driver to layer
#   container image layers efficiently.
# - br_netfilter: Enables Linux bridge traffic to be filtered by Netfilter
#   (iptables/nftables). Essential for kube-proxy and Calico to inspect and route
#   bridged virtual ethernet (veth) packet flows.
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

echo "=========================================================="
echo ">>> [3/4] Configuring Linux Kernel Sysctl Parameters"
echo "=========================================================="
# WHY:
# - net.bridge.bridge-nf-call-iptables: Ensures packets traversing a Linux bridge
#   are passed to iptables for processing. Without this, service routing fails.
# - net.ipv4.ip_forward: Enables Linux kernel packet forwarding between different
#   network interfaces (e.g. eth0, cali*, and veth pairs for pods).
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system

echo "=========================================================="
echo ">>> [4/4] Verifying Kernel Configuration"
echo "=========================================================="
lsmod | grep -E "(overlay|br_netfilter)"
sysctl net.bridge.bridge-nf-call-iptables net.ipv4.ip_forward

echo ">>> Node OS & Kernel prerequisites successfully configured!"

#!/bin/bash
# =============================================================================
# 02-install-kubernetes.sh: Install kubelet, kubeadm, kubectl
# Must be executed on ALL nodes (Control Plane and Workers)
# =============================================================================
set -euo pipefail

K8S_VERSION="v1.30"

echo "=========================================================="
echo ">>> [1/4] Installing Official Kubernetes APT Repository"
echo "=========================================================="
sudo apt-get update -y
sudo apt-get install -y apt-transport-https ca-certificates curl gpg

# Download Kubernetes package signing key (modern pkgs.k8s.io structure)
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key | \
  sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --yes

echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" | \
  sudo tee /etc/apt/sources.list.d/kubernetes.list

echo "=========================================================="
echo ">>> [2/4] Installing kubelet, kubeadm, and kubectl"
echo "=========================================================="
sudo apt-get update -y
sudo apt-get install -y kubelet kubeadm kubectl

echo "=========================================================="
echo ">>> [3/4] Pinning Kubernetes Package Versions (apt-mark hold)"
echo "=========================================================="
# WHY apt-mark hold:
# Automated OS package updates (like unattended-upgrades) could bump kubelet or
# kubeadm to a minor version ahead of the control plane. Kubernetes enforces strict
# version skew policies: kubelet must never be newer than kube-apiserver.
# Holding prevents catastrophic automated cluster drift.
sudo apt-mark hold kubelet kubeadm kubectl

echo "=========================================================="
echo ">>> [4/4] Enabling kubelet Service & Shell Completions"
echo "=========================================================="
sudo systemctl enable --now kubelet

# Shell completion and aliases for productivity
echo "source <(kubectl completion bash)" >> ~/.bashrc
echo "alias k=kubectl" >> ~/.bashrc
echo "complete -o default -F __start_kubectl k" >> ~/.bashrc

echo ">>> Kubernetes binaries installed and pinned successfully:"
kubeadm version -o short
kubelet --version
kubectl version --client -o yaml

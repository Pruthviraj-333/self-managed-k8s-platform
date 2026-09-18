#!/bin/bash
# =============================================================================
# 03-init-control-plane.sh: Initialize Kubernetes Control Plane Node
# Run ONLY on the Control Plane node (k8s-cp1)
# =============================================================================
set -euo pipefail

echo "=========================================================="
echo ">>> [1/4] Running kubeadm init"
echo "=========================================================="
# If a public IP is available, automatically inject it into certSANs
PUBLIC_IP=$(curl -s http://169.254.169.254/latest/meta-data/public-ipv4 || true)
if [ -n "$PUBLIC_IP" ] && ! grep -q "$PUBLIC_IP" kubeadm-config.yaml; then
  echo ">>> Detected AWS Public IP: $PUBLIC_IP. Appending to certSANs in kubeadm-config.yaml"
  sed -i "/certSANs:/a \  - \"$PUBLIC_IP\"" kubeadm-config.yaml
fi

sudo kubeadm init --config kubeadm-config.yaml --upload-certs | tee kubeadm-init.log

echo "=========================================================="
echo ">>> [2/4] Configuring kubectl for Current User"
echo "=========================================================="
mkdir -p "$HOME/.kube"
sudo cp -i /etc/kubernetes/admin.conf "$HOME/.kube/config"
sudo chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo "=========================================================="
echo ">>> [3/4] Examining Generated PKI & Static Pod Manifests"
echo "=========================================================="
echo "--- PKI Certificates (/etc/kubernetes/pki) ---"
sudo ls -lh /etc/kubernetes/pki

echo "--- Static Pod Manifests (/etc/kubernetes/manifests) ---"
sudo ls -lh /etc/kubernetes/manifests

echo "=========================================================="
echo ">>> [4/4] Extracting Worker Node Join Command"
echo "=========================================================="
JOIN_CMD=$(kubeadm token create --print-join-command)
echo "Worker Join Command:"
echo "$JOIN_CMD"
echo "$JOIN_CMD" > join-command.sh
chmod +x join-command.sh

echo ""
echo ">>> Control Plane initialized! Check initial node status:"
kubectl get nodes -o wide
echo ""
echo "NOTE: The node will show status 'NotReady' until Calico CNI is installed."

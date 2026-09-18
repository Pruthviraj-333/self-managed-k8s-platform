#!/bin/bash
# =============================================================================
# 04-join-workers.sh: Join Worker Node to the Self-Managed Cluster
# Run ONLY on Worker Nodes (k8s-worker1, k8s-worker2)
# =============================================================================
set -euo pipefail

echo "=========================================================="
echo ">>> Joining Worker Node to Cluster"
echo "=========================================================="

# Replace the command below with the exact output from:
# 'kubeadm token create --print-join-command' run on k8s-cp1
#
# Technical Explanation of the parameters:
# 1. <CONTROL_PLANE_IP>:6443 -> Direct TCP connection to kube-apiserver
# 2. --token <token-id>.<token-secret> -> Bootstrap token stored as a secret in kube-system.
#    Used for mutual authentication before the worker has its own x509 cert.
# 3. --discovery-token-ca-cert-hash sha256:<hash> -> Cryptographic thumbprint of the root CA.
#    Ensures the worker does not join an imposter control plane (MITM defense).

if [ ! -f ./join-command.sh ]; then
  echo "Error: join-command.sh not found."
  echo "Copy the join-command.sh generated on k8s-cp1 or paste your join command here:"
  echo "Example: sudo kubeadm join 10.0.1.10:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>"
  exit 1
fi

sudo bash ./join-command.sh

echo ">>> Worker joined successfully! Verify on the control plane via: 'kubectl get nodes -o wide'"

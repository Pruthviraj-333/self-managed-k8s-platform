#!/bin/bash
# =============================================================================
# configure-containerd-registry.sh: Trust In-Cluster Local Registry in containerd
# Run on all worker nodes to allow pulling images from 10.0.1.10:30500
# =============================================================================
set -euo pipefail

REGISTRY_ENDPOINT="10.0.1.10:30500"

echo "Configuring containerd to trust HTTP registry at $REGISTRY_ENDPOINT..."

sudo mkdir -p "/etc/containerd/certs.d/${REGISTRY_ENDPOINT}"
cat <<EOF | sudo tee "/etc/containerd/certs.d/${REGISTRY_ENDPOINT}/hosts.toml"
server = "http://${REGISTRY_ENDPOINT}"

[host."http://${REGISTRY_ENDPOINT}"]
  capabilities = ["pull", "resolve", "push"]
  skip_verify = true
EOF

sudo systemctl restart containerd
echo ">>> containerd configured for local registry!"

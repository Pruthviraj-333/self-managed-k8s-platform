#!/bin/bash
# =============================================================================
# 01-install-containerd.sh: Container Runtime Interface (CRI) Setup
# Must be executed on ALL nodes (Control Plane and Workers)
# =============================================================================
set -euo pipefail

echo "=========================================================="
echo ">>> [1/4] Installing Required System Utilities"
echo "=========================================================="
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release

echo "=========================================================="
echo ">>> [2/4] Adding Docker / Containerd Official Repository"
echo "=========================================================="
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg --yes
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y containerd.io

echo "=========================================================="
echo ">>> [3/4] Configuring containerd with Systemd Cgroup Driver"
echo "=========================================================="
# WHY SystemdCgroup = true:
# In modern Linux distributions (systemd-based), systemd is the root init process
# and acts as the primary cgroup manager.
# If containerd uses the raw 'cgroupfs' driver while the OS uses systemd,
# two concurrent managers try to allocate CPU/memory cgroups, leading to race
# conditions, resource accounting leaks, and unstable pods under memory pressure.
# Using 'SystemdCgroup = true' aligns Kubernetes, containerd, and Linux systemd.
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml > /dev/null

# Replace SystemdCgroup = false with true in config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' /etc/containerd/config.toml

# Verify the setting is applied
grep -n "SystemdCgroup = true" /etc/containerd/config.toml

echo "=========================================================="
echo ">>> [4/4] Starting and Enabling containerd Service"
echo "=========================================================="
sudo systemctl daemon-reload
sudo systemctl restart containerd
sudo systemctl enable containerd

echo ">>> Container runtime (containerd) successfully installed and active!"
systemctl status containerd --no-pager | head -n 10

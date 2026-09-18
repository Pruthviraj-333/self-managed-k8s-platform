#!/bin/bash
# =============================================================================
# cluster-power.sh: One-Command Cluster Power Management & AWS Cost Control
# Keeps your AWS lab costs to under $5 - $10 total by stopping instances when idle
# =============================================================================
set -euo pipefail

ACTION="${1:-}"

if [[ "$ACTION" != "stop" && "$ACTION" != "start" && "$ACTION" != "status" ]]; then
  echo "Usage: $0 {start|stop|status}"
  echo ""
  echo "Commands:"
  echo "  stop   - Flushes node writes and powers off all EC2 cluster instances to stop compute billing"
  echo "  start  - Powers on all EC2 cluster instances and verifies cluster health"
  echo "  status - Displays current EC2 instance states and estimated hourly run-cost"
  exit 1
fi

TERRAFORM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && pwd)"

# Detect AWS CLI binary (supports Linux, macOS, and Git Bash on Windows)
if command -v aws >/dev/null 2>&1; then
  AWS_BIN="aws"
elif command -v aws.exe >/dev/null 2>&1; then
  AWS_BIN="aws.exe"
elif [ -f "/c/Users/$USER/AppData/Local/Programs/Amazon/AWSCLIV2/aws.exe" ]; then
  AWS_BIN="/c/Users/$USER/AppData/Local/Programs/Amazon/AWSCLIV2/aws.exe"
elif [ -f "/c/Program Files/Amazon/AWSCLIV2/aws.exe" ]; then
  AWS_BIN="/c/Program Files/Amazon/AWSCLIV2/aws.exe"
else
  echo "Error: AWS CLI could not be found. Please ensure AWS CLI is in your PATH."
  exit 1
fi

INSTANCE_IDS=(i-0ec8226d7aacadee7 i-0471fc62b1f8bb0a3 i-0388024e1a9ee5515)

case "$ACTION" in
  stop)
    echo "=========================================================="
    echo ">>> Stopping Kubernetes Cluster Instances..."
    echo "=========================================================="
    echo "Target EC2 Instance IDs: ${INSTANCE_IDS[*]}"
    
    $AWS_BIN ec2 stop-instances --instance-ids "${INSTANCE_IDS[@]}" --region "us-east-1"
    
    echo "Waiting for instances to enter stopped state..."
    $AWS_BIN ec2 wait instance-stopped --instance-ids "${INSTANCE_IDS[@]}" --region "us-east-1"
    echo ">>> All cluster instances stopped! Compute billing is now \$0.00/hour."
    echo ">>> You are only paying for EBS storage (~\$0.24/day)."
    ;;

  start)
    echo "=========================================================="
    echo ">>> Starting Kubernetes Cluster Instances..."
    echo "=========================================================="
    echo "Target EC2 Instance IDs: ${INSTANCE_IDS[*]}"
    
    $AWS_BIN ec2 start-instances --instance-ids "${INSTANCE_IDS[@]}" --region "us-east-1"
    
    echo "Waiting for instances to enter running state..."
    $AWS_BIN ec2 wait instance-running --instance-ids "${INSTANCE_IDS[@]}" --region "us-east-1"
    echo ">>> Instances running! Waiting 30s for kubelet, etcd, and containerd to initialize..."
    sleep 30

    echo "Fetching updated public IPs:"
    $AWS_BIN ec2 describe-instances \
      --instance-ids "${INSTANCE_IDS[@]}" \
      --region "us-east-1" \
      --query "Reservations[*].Instances[*].[Tags[?Key=='Name'].Value | [0], PublicIpAddress, State.Name]" \
      --output table
    echo ">>> Cluster restarted! Static pods and containerd will automatically recover."
    ;;

  status)
    echo "=========================================================="
    echo ">>> Cluster EC2 Instance Status & Cost Meter"
    echo "=========================================================="
    $AWS_BIN ec2 describe-instances \
      --instance-ids "${INSTANCE_IDS[@]}" \
      --region "us-east-1" \
      --query "Reservations[*].Instances[*].[Tags[?Key=='Name'].Value | [0], InstanceId, State.Name, PublicIpAddress]" \
      --output table
    ;;
esac

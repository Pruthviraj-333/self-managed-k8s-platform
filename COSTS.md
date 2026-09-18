# AWS EC2 Cost Analysis & Budget Management Guide

This project is specifically engineered to give you complete, production-grade self-managed Kubernetes experience while keeping your AWS cloud bill **under $5 to $10 total** for your entire study and interview demonstration period.

---

## 1. Itemized Cost Breakdown (AWS `us-east-1` Pricing)

| Resource | Quantity & Spec | Hourly Cost | Daily Cost (24/7) | Monthly Cost (24/7) | Idle Cost (Instances Stopped) |
|---|---|---|---|---|---|
| **Control Plane VM** | 1x `c7i-flex.large` / `t3.medium` (2 vCPU, 4GB RAM) | $0.0416 - $0.0726 | $1.00 - $1.74 | $29.95 - $52.27 | **$0.00** |
| **Worker Nodes** | 2x `c7i-flex.large` / `t3.medium` (2 vCPU, 4GB RAM) | $0.0832 - $0.1452 | $2.00 - $3.48 | $59.90 - $104.54 | **$0.00** |
| **EBS Storage** | 3x 30GB gp3 (90GB total) | $0.0100 | $0.24 | $7.20 | **$0.24 / day** |
| **Public IPv4 Addresses** | 3x Public IPs ($0.005/hr each) | $0.0150 | $0.36 | $10.80 | **$0.00** |
| **AWS NAT Gateway** | *ELIMINATED* (Direct IGW) | **$0.00** | **$0.00** | **$0.00** | **$0.00** |
| **AWS Elastic Load Balancer** | *ELIMINATED* (MetalLB L2) | **$0.00** | **$0.00** | **$0.00** | **$0.00** |
| **Total Lab Cost** | | **~$0.15 - $0.24 / hr** | **~$3.60 - $5.80 / day** | **~$108 - $174 / mo** | **~$0.24 / day** |

> [!NOTE]
> In `us-east-1`, accounts with modern EC2 quota tiers use `c7i-flex.large` (2 vCPU, 4GB RAM, latest Gen Intel Xeon Scalable) which provides high single-thread performance for kubeadm bootstraps at comparable spot/on-demand pricing.

---

## 2. Architectural Cost-Savings: How We Avoided Hidden Cloud Fees

1. **Eliminated AWS NAT Gateway ($32.40/month saved)**:
   - In traditional VPC designs, private subnets route outbound internet traffic through an AWS Managed NAT Gateway ($0.045/hour + $0.045/GB data processed).
   - *Our Design*: We assign public IPs and route directly through an Internet Gateway (IGW), which incurs **$0.00/hour**, protecting all internal services via Security Groups.
2. **Eliminated AWS Network/Application Load Balancer ($22.00/month saved per LB)**:
   - Creating a `type: LoadBalancer` service on AWS normally triggers an NLB/ALB costing $0.0225/hour + LCU charges.
   - *Our Design*: We deploy **MetalLB in Layer 2 mode**, utilizing internal VPC IPs and ARP broadcasting. It costs **$0.00** in cloud fees.
3. **Eliminated AWS EBS CSI dynamic volume API fees**:
   - Instead of provisioning 10 different EBS volumes for each microservice or monitoring PVC, we use **Rancher Local Path Provisioner** on the existing 30GB root volume.

---

## 3. Realistic Billing Scenarios

### Scenario A: Active Study & Demo Mode (Recommended)
- **Pattern**: Run cluster for 3 hours per session, 5 sessions over 2 weeks. Stop instances when not in use.
- Compute hours: 15 hours x ~$0.20/hr = **~$3.00**
- EBS storage: 14 days x $0.24/day = **$3.36**
- **TOTAL ESTIMATED AWS BILL**: **~$6.36**

### Scenario B: Accidental Always-On (Warning!)
- Leaving the cluster running 24/7 for 30 days will cost **~$108 - $174**.
- Set up an AWS Billing Alert at **$10.00** in the AWS Billing Console to prevent surprises!

---

## 4. Power Management Workflow

When you finish a study or demo session, power off the instances. EBS gp3 storage preserves all cluster state, etcd databases, and workload data while compute fees drop to **$0.00**.

### Windows PowerShell (Recommended for Windows):
```powershell
# 1. Check current power status of all nodes
.\scripts\cluster-power.ps1 status

# 2. Power off instances (stops compute billing immediately)
.\scripts\cluster-power.ps1 stop

# 3. Resume cluster when starting a new session
.\scripts\cluster-power.ps1 start
```

### Linux / macOS Bash:
```bash
# 1. Check status
bash scripts/cluster-power.sh status

# 2. Power off instances
bash scripts/cluster-power.sh stop

# 3. Resume cluster
bash scripts/cluster-power.sh start
```

### Complete Teardown (Permanent Cleanup):
When you are completely finished with the project and do not need the cluster anymore:
```bash
cd terraform
terraform destroy -auto-approve
```
*Effect*: Destroys all EC2 instances, EBS volumes, security groups, and the VPC. Ongoing AWS billing becomes strictly **$0.00**.

<#
.SYNOPSIS
    One-Command Cluster Power Management & AWS Cost Control for Windows PowerShell.
.DESCRIPTION
    Stops or starts all 3 Kubernetes cluster EC2 instances in AWS us-east-1.
    Halts compute billing while safely preserving all cluster state, etcd, and local storage.
.EXAMPLE
    .\scripts\cluster-power.ps1 stop
    .\scripts\cluster-power.ps1 start
    .\scripts\cluster-power.ps1 status
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, Position = 0)]
    [ValidateSet("start", "stop", "status")]
    [string]$Action
)

$Region = "us-east-1"
$InstanceIds = @("i-0ec8226d7aacadee7", "i-0471fc62b1f8bb0a3", "i-0388024e1a9ee5515")

switch ($Action) {
    "stop" {
        Write-Host "==========================================================" -ForegroundColor Yellow
        Write-Host ">>> Stopping Kubernetes Cluster Instances..." -ForegroundColor Yellow
        Write-Host "==========================================================" -ForegroundColor Yellow
        Write-Host "Target EC2 Instance IDs: $($InstanceIds -join ', ')"
        
        aws ec2 stop-instances --instance-ids $InstanceIds --region $Region
        Write-Host "Waiting for instances to enter stopped state..."
        aws ec2 wait instance-stopped --instance-ids $InstanceIds --region $Region
        
        Write-Host ""
        Write-Host ">>> All cluster instances stopped successfully!" -ForegroundColor Green
        Write-Host ">>> Compute billing is now `$0.00/hour." -ForegroundColor Green
        Write-Host ">>> You are only paying for EBS storage (~`$0.24/day)." -ForegroundColor Cyan
    }

    "start" {
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host ">>> Starting Kubernetes Cluster Instances..." -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host "Target EC2 Instance IDs: $($InstanceIds -join ', ')"
        
        aws ec2 start-instances --instance-ids $InstanceIds --region $Region
        Write-Host "Waiting for instances to enter running state..."
        aws ec2 wait instance-running --instance-ids $InstanceIds --region $Region
        
        Write-Host "Instances running! Waiting 30s for kubelet, containerd, and static pods to initialize..."
        Start-Sleep -Seconds 30

        Write-Host ""
        Write-Host "Fetching updated public IPs:" -ForegroundColor Green
        aws ec2 describe-instances `
            --instance-ids $InstanceIds `
            --region $Region `
            --query "Reservations[*].Instances[*].[Tags[?Key=='Name'].Value | [0], PublicIpAddress, State.Name]" `
            --output table
        Write-Host ">>> Cluster restarted! Static pods and workloads will automatically recover." -ForegroundColor Green
    }

    "status" {
        Write-Host "==========================================================" -ForegroundColor Cyan
        Write-Host ">>> Cluster EC2 Instance Status & Cost Meter" -ForegroundColor Cyan
        Write-Host "==========================================================" -ForegroundColor Cyan
        aws ec2 describe-instances `
            --instance-ids $InstanceIds `
            --region $Region `
            --query "Reservations[*].Instances[*].[Tags[?Key=='Name'].Value | [0], InstanceId, State.Name, PublicIpAddress]" `
            --region $Region `
            --output table
    }
}

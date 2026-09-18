variable "aws_region" {
  description = "AWS region to deploy raw EC2 instances"
  type        = string
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the cluster VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "Subnet CIDR for raw EC2 nodes"
  type        = string
  default     = "10.0.1.0/24"
}

variable "admin_ip" {
  description = "Your workstation IP for SSH and kube-apiserver access (e.g. 203.0.113.5/32 or 0.0.0.0/0 for testing)"
  type        = string
  default     = "0.0.0.0/0"
}

variable "key_name" {
  description = "AWS EC2 Key Pair name for SSH access"
  type        = string
  default     = "k8s-cluster-key"
}

variable "control_plane_instance_type" {
  description = "EC2 instance size for control plane (2 vCPU, 4GB RAM minimum for etcd/apiserver)"
  type        = string
  default     = "t3.medium"
}

variable "worker_instance_type" {
  description = "EC2 instance size for worker nodes (t3.medium or t3.large recommended for microservices + monitoring)"
  type        = string
  default     = "t3.medium"
}

variable "worker_count" {
  description = "Number of worker nodes to provision"
  type        = number
  default     = 2
}

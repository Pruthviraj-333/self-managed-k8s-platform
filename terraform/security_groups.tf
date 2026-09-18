# -----------------------------------------------------------------------------
# Kubernetes Security Group
# Demonstrates precise knowledge of self-managed K8s port requirements
# -----------------------------------------------------------------------------

resource "aws_security_group" "k8s_sg" {
  name        = "k8s-cluster-sg"
  description = "Firewall rules for self-managed Kubernetes nodes (kubeadm, etcd, kubelet, calico)"
  vpc_id      = aws_vpc.k8s_vpc.id

  # --- SSH Administration ---
  ingress {
    description = "SSH access from administrator workstation"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_ip]
  }

  # --- Kubernetes API Server ---
  ingress {
    description = "Kubernetes API Server access"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = [var.admin_ip, var.subnet_cidr]
  }

  # --- Internal Cluster Communication (Intra-Node / Intra-VPC) ---
  # Essential for etcd quorum, kubelet metrics, scheduler, and controller-manager
  ingress {
    description = "Full intra-cluster communication between all nodes in the subnet"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.subnet_cidr]
  }

  # --- Calico CNI Overlay Traffic (Pod Network: 192.168.0.0/16) ---
  ingress {
    description = "Calico VXLAN encapsulation"
    from_port   = 4789
    to_port     = 4789
    protocol    = "udp"
    cidr_blocks = [var.subnet_cidr]
  }

  ingress {
    description = "Calico BGP routing"
    from_port   = 179
    to_port     = 179
    protocol    = "tcp"
    cidr_blocks = [var.subnet_cidr]
  }

  ingress {
    description = "Calico IP-in-IP encapsulation (IP Protocol 4)"
    from_port   = 0
    to_port     = 0
    protocol    = "4"
    cidr_blocks = [var.subnet_cidr]
  }

  # --- MetalLB Layer 2 & Ingress HTTP/HTTPS ---
  ingress {
    description = "HTTP ingress to MetalLB VIP and NodePorts"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS ingress to MetalLB VIP and NodePorts"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # --- Kubernetes NodePort Range ---
  ingress {
    description = "Kubernetes NodePort service range (30000-32767)"
    from_port   = 30000
    to_port     = 32767
    protocol    = "tcp"
    cidr_blocks = [var.admin_ip, var.subnet_cidr]
  }

  # --- Outbound Internet Access ---
  egress {
    description = "Allow all outbound internet traffic for package repos, images, and updates"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "k8s-cluster-sg"
  }
}

# -----------------------------------------------------------------------------
# EC2 Instances for Self-Managed Kubernetes
# Note: Raw Linux VMs only. No EKS or AWS Kubernetes helpers.
# -----------------------------------------------------------------------------

# Fetch the official Ubuntu 22.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# Control Plane Node (k8s-cp1)
# -----------------------------------------------------------------------------
resource "aws_instance" "control_plane" {
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.control_plane_instance_type
  subnet_id                   = aws_subnet.k8s_subnet.id
  private_ip                  = "10.0.1.10"
  vpc_security_group_ids      = [aws_security_group.k8s_sg.id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  # CRITICAL FOR ON-PREM CNI (Calico/Flannel):
  # AWS checks whether an instance is the source or destination of traffic it forwards.
  # Pod CIDRs (192.168.0.0/16) are routed by nodes, so source_dest_check MUST be disabled.
  source_dest_check = false

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    tags = {
      Name = "k8s-cp1-root-disk"
    }
  }

  user_data = <<-EOF
              #!/bin/bash
              hostnamectl set-hostname k8s-cp1
              echo "10.0.1.10 k8s-cp1" >> /etc/hosts
              echo "10.0.1.20 k8s-worker1" >> /etc/hosts
              echo "10.0.1.21 k8s-worker2" >> /etc/hosts
              EOF

  tags = {
    Name = "k8s-cp1"
    Role = "control-plane"
  }
}

# -----------------------------------------------------------------------------
# Worker Nodes (k8s-worker1, k8s-worker2)
# -----------------------------------------------------------------------------
resource "aws_instance" "workers" {
  count                       = var.worker_count
  ami                         = data.aws_ami.ubuntu.id
  instance_type               = var.worker_instance_type
  subnet_id                   = aws_subnet.k8s_subnet.id
  private_ip                  = "10.0.1.${20 + count.index}"
  vpc_security_group_ids      = [aws_security_group.k8s_sg.id]
  key_name                    = var.key_name
  associate_public_ip_address = true

  # Disable source/dest checking for CNI overlay / routed traffic
  source_dest_check = false

  root_block_device {
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    tags = {
      Name = "k8s-worker${count.index + 1}-root-disk"
    }
  }

  user_data = <<-EOF
              #!/bin/bash
              hostnamectl set-hostname k8s-worker${count.index + 1}
              echo "10.0.1.10 k8s-cp1" >> /etc/hosts
              echo "10.0.1.20 k8s-worker1" >> /etc/hosts
              echo "10.0.1.21 k8s-worker2" >> /etc/hosts
              EOF

  tags = {
    Name = "k8s-worker${count.index + 1}"
    Role = "worker"
  }
}

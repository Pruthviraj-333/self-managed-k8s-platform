output "vpc_id" {
  description = "Cluster VPC ID"
  value       = aws_vpc.k8s_vpc.id
}

output "subnet_id" {
  description = "Subnet ID"
  value       = aws_subnet.k8s_subnet.id
}

output "control_plane_public_ip" {
  description = "Public IP of Control Plane Node"
  value       = aws_instance.control_plane.public_ip
}

output "control_plane_private_ip" {
  description = "Private IP of Control Plane Node"
  value       = aws_instance.control_plane.private_ip
}

output "worker_public_ips" {
  description = "Public IPs of Worker Nodes"
  value       = aws_instance.workers[*].public_ip
}

output "worker_private_ips" {
  description = "Private IPs of Worker Nodes"
  value       = aws_instance.workers[*].private_ip
}

output "ssh_commands" {
  description = "Commands to SSH into the nodes"
  value = {
    control_plane = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_instance.control_plane.public_ip}"
    worker_1      = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_instance.workers[0].public_ip}"
    worker_2      = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_instance.workers[1].public_ip}"
  }
}

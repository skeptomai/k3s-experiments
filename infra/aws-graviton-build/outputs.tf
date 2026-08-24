output "instance_id" {
  description = "EC2 instance ID -- used by the stop/start wrapper script."
  value       = aws_instance.build_node.id
}

output "tailnet_hostname" {
  description = "Expected MagicDNS name once Tailscale enrollment completes."
  value       = "${var.hostname}.taildd208.ts.net"
}

output "availability_zone" {
  value = aws_instance.build_node.availability_zone
}

output "wireguard_endpoint" {
  description = "Stable public IP for the MikroTik's WireGuard peer endpoint-address."
  value       = aws_eip.build_node.public_ip
}

output "vpc_private_ip" {
  description = "The instance's VPC private IP -- used as the k3s node-ip after peering (k3s-experiments#20)."
  value       = aws_instance.build_node.private_ip
}

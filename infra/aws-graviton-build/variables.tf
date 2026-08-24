variable "aws_region" {
  description = "AWS region for the build node."
  type        = string
  default     = "us-west-2"
}

variable "aws_profile" {
  description = "AWS CLI profile to use."
  type        = string
  default     = "administrator"
}

variable "instance_type" {
  description = "Graviton4 instance type. Sized for single-build-at-a-time use."
  type        = string
  default     = "c8g.2xlarge"
}

variable "root_volume_size_gb" {
  description = "Root EBS volume size in GB (gp3). Persists across stop/start."
  type        = number
  default     = 100
}

variable "hostname" {
  description = "Hostname advertised to Tailscale (becomes <hostname>.taildd208.ts.net)."
  type        = string
  default     = "aws-graviton-build"
}

variable "tailscale_authkey" {
  description = "Tailscale auth key (tagged, reusable) minted for this node. Passed at apply time, never committed."
  type        = string
  sensitive   = true
}

variable "ssh_public_key" {
  description = "Fallback SSH public key installed via cloud-init, in case Tailscale enrollment fails and direct AWS-side access is needed."
  type        = string
  default     = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQC/jbfap70ek09uy4a+wk8peK3dZ99UMkk3BGKLGupDOfV8sBfEbB5cjjoemYL8s/4r9O7oJtkI+WQbfOwzK38gH0CU5Y3NHr4qEZ7ESkVYbBuXiMXhcjwysTBHwjV0MFYzLdpEdMB5s5SmMSXT3eTfVtRvWH6VQl2fWujCxxn4Rhj2pHUOuisFg/pwCxerertbNd8ryK6dqqXFZ9P++hyMz46uVxxHhE6HIqL5PCSeny9ZiIJSqjitzq3Z2jHQsOgw7E52SQMLCzhw8qRriGFrCdOZhpyOR49UEVi5nrGSwRlA6Xrlvj4kd1VxiduFy4beYiaL4IaDJ7PoOkoeqdMFWUKmQLYxGaq2+HIxe3Whv0R27o4et1gSbxhukAzHrF1ITqK6KgulJUG1tgCAcGDc/lhLMS/L0m5raOaZ/d9xXAHSEm/WFctciOvjZNIpWS5dthpT3gYGV2O4AJWZmGDPjQdWU18xnZyKWEq2CQXkF0+WHZD3hFrO8CjpErDOa7k= cb@omen"
}

variable "tailscale_tags" {
  description = "Tailscale ACL tags applied to this node."
  type        = list(string)
  default     = ["tag:cloud-build"]
}

variable "wireguard_port" {
  description = "UDP port for the site-to-site WireGuard tunnel to the home MikroTik (k3s-experiments#20)."
  type        = number
  default     = 51820
}

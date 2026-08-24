# Reuses the account's existing default VPC -- no new networking, this is a
# single dev/build box, not a service that needs its own network segment.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}

data "aws_ssm_parameter" "ubuntu_arm64" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/arm64/hvm/ebs-gp3/ami-id"
}

# SSH/admin access stays Tailscale-only (no inbound needed for that). The one
# inbound rule is for the site-to-site WireGuard tunnel to the home LAN
# (k3s-experiments#20) -- open to 0.0.0.0/0 since the MikroTik's home WAN IP
# is dynamic; safe for WireGuard specifically since it never responds to an
# unauthenticated handshake, so it's invisible to scanners regardless.
resource "aws_security_group" "build_node" {
  # name_prefix (not a fixed name) -- required for create_before_destroy below:
  # AWS enforces unique SG names per VPC, so the replacement SG must get a
  # different generated name while briefly coexisting with the old one.
  name_prefix = "${var.hostname}-sg-"
  description = "AWS Graviton build node -- Tailscale-only admin access, WireGuard site-to-site for cluster networking (k3s-experiments#20)"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "WireGuard site-to-site tunnel from the home MikroTik router"
    from_port   = var.wireguard_port
    to_port     = var.wireguard_port
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "allow all outbound (apt, tailscale coordination, image pulls, github)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = var.hostname
    Purpose = "arm64-build-node"
  }

  # Without this, a change that forces replacement (e.g. description, which
  # AWS makes immutable) destroys the old SG BEFORE creating the new one --
  # and AWS refuses to delete a security group still attached to a running
  # instance's ENI, so the apply hangs/fails. create_before_destroy fixes
  # the ordering: new SG created and attached first, old one torn down after.
  lifecycle {
    create_before_destroy = true
  }
}

# Stable rendezvous address for the MikroTik to dial -- the instance's normal
# public IP would change on every stop/start otherwise, breaking the tunnel's
# peer config. Billed per-hour regardless of attachment state (~$3.60/mo).
resource "aws_eip" "build_node" {
  instance = aws_instance.build_node.id
  domain   = "vpc"

  tags = {
    Name    = "${var.hostname}-wireguard"
    Purpose = "wireguard-rendezvous"
  }
}

resource "aws_instance" "build_node" {
  ami                    = data.aws_ssm_parameter.ubuntu_arm64.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default.ids[0]
  vpc_security_group_ids = [aws_security_group.build_node.id]

  root_block_device {
    volume_type = "gp3"
    volume_size = var.root_volume_size_gb
    encrypted   = true
  }

  user_data = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    authkey        = var.tailscale_authkey
    hostname       = var.hostname
    tags           = join(",", var.tailscale_tags)
    ssh_public_key = var.ssh_public_key
  })

  # Preserved across stop/start; only lost on terminate. We stop, never
  # terminate, for routine idle periods -- see scripts/aws-build-node-*.sh.
  tags = {
    Name    = var.hostname
    Purpose = "arm64-build-node"
  }

  lifecycle {
    ignore_changes = [
      ami,       # don't force a replace when Canonical publishes a newer AMI
      user_data, # one-time bootstrap only -- cloud-init never re-runs on an existing instance,
                 # so diffing this against a freshly-minted authkey is meaningless noise, not a real change
    ]
  }
}

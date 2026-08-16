locals {
  name = var.name_prefix

  tags = merge(
    {
      Name      = var.name_prefix
      ManagedBy = "terraform"
      Component = "wirenboard-cloud-on-premise"
    },
    var.tags,
  )

  vpc_id    = var.vpc_id != null ? var.vpc_id : data.aws_vpc.default[0].id
  subnet_id = var.subnet_id != null ? var.subnet_id : data.aws_subnets.default[0].ids[0]

  # The cloud answers on the host itself and on four subdomain groups; the same
  # list is what the certificate has to cover.
  dns_names = [
    var.domain,
    "*.${var.domain}",
    "*.ssh.${var.domain}",
    "*.http.${var.domain}",
    "*.apps.${var.domain}",
  ]

  # The empty fallback is what makes a misconfiguration report itself through the
  # preconditions below instead of failing on a null attribute first.
  smtp_settings = var.enable_ses ? {
    host               = "email-smtp.${data.aws_region.current.name}.amazonaws.com"
    port               = 587
    user               = aws_iam_access_key.ses[0].id
    password           = aws_iam_access_key.ses[0].ses_smtp_password_v4
    use_ssl            = false
    notifications_from = "noreply@${var.domain}"
    } : var.smtp != null ? var.smtp : {
    host               = ""
    port               = 587
    user               = ""
    password           = ""
    use_ssl            = false
    notifications_from = ""
  }

  env = merge(
    {
      ABSOLUTE_SERVER        = var.domain
      ADMIN_EMAIL            = var.admin_email
      EMAIL_ENABLED          = var.email_enabled ? "True" : "False"
      METRICS_RETENTION_DAYS = tostring(var.metrics_retention_days)
      TUNNEL_PORT            = tostring(var.tunnel_port)
      TUNNEL_DASHBOARD_PORT  = tostring(var.tunnel_dashboard_port)
    },
    var.email_enabled ? {
      EMAIL_HOST               = local.smtp_settings.host
      EMAIL_PORT               = tostring(local.smtp_settings.port)
      EMAIL_HOST_USER          = local.smtp_settings.user
      EMAIL_HOST_PASSWORD      = local.smtp_settings.password
      EMAIL_USE_SSL            = local.smtp_settings.use_ssl ? "True" : "False"
      EMAIL_NOTIFICATIONS_FROM = local.smtp_settings.notifications_from
    } : {},
    var.admin_password != null ? { ADMIN_PASSWORD = var.admin_password } : {},
    var.extra_env,
  )
}

data "aws_region" "current" {}

data "aws_vpc" "default" {
  count   = var.vpc_id == null ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = var.subnet_id == null ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}

data "aws_subnet" "selected" {
  id = local.subnet_id
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
}

resource "aws_security_group" "this" {
  name        = "${local.name}-sg"
  description = "Wiren Board Cloud on-premise"
  vpc_id      = local.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "web" {
  for_each = toset(var.allowed_web_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "HTTPS: web interface, API, agent, metrics ingest, tunnel proxying"
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "tunnel" {
  for_each = toset(var.allowed_tunnel_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "Controller tunnels (FRP)"
  cidr_ipv4         = each.value
  from_port         = var.tunnel_port
  to_port           = var.tunnel_port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "tunnel_dashboard" {
  for_each = toset(var.tunnel_dashboard_cidrs)

  security_group_id = aws_security_group.this.id
  description       = "Tunnel dashboard"
  cidr_ipv4         = each.value
  from_port         = var.tunnel_dashboard_port
  to_port           = var.tunnel_dashboard_port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count = var.key_name != null ? 1 : 0

  security_group_id = aws_security_group.this.id
  description       = "SSH"
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

# The installation pulls images, the GeoIP database and the certificate, and the
# cloud keeps reporting to on-premise-metrics.wirenboard.cloud.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  description       = "Outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Separate from the root disk so that replacing the instance does not take the
# databases with it.
resource "aws_ebs_volume" "data" {
  # Taken from the subnet, not from the instance: the instance's user_data needs
  # this volume's id, and reading it back from the instance would be a cycle.
  availability_zone = data.aws_subnet.selected.availability_zone
  size              = var.data_volume_size
  type              = "gp3"
  encrypted         = true
  tags              = merge(local.tags, { Name = "${local.name}-data" })

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id
}

resource "aws_instance" "this" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id
  vpc_security_group_ids = [aws_security_group.this.id]
  iam_instance_profile   = aws_iam_instance_profile.this.name
  key_name               = var.key_name
  user_data              = local.user_data
  tags                   = local.tags

  # The installation needs the internet before the Elastic IP is attached, and a
  # custom subnet may not hand out a public address on its own.
  associate_public_ip_address = true

  root_block_device {
    volume_size = var.root_volume_size
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens   = "required"
    http_endpoint = "enabled"
  }

  lifecycle {
    # Changing the installed version must not recreate the instance: the data
    # volume would survive, but the cloud upgrades through `make upgrade`.
    ignore_changes = [user_data, ami]

    precondition {
      condition     = !var.enable_ses || var.email_enabled
      error_message = "enable_ses requires email_enabled = true."
    }

    precondition {
      condition     = !var.email_enabled || var.enable_ses || var.smtp != null
      error_message = "email_enabled = true requires either enable_ses = true or an smtp block."
    }
  }
}

resource "aws_eip" "this" {
  instance = aws_instance.this.id
  domain   = "vpc"
  tags     = local.tags
}

locals {
  user_data = templatefile("${path.module}/cloud-init.sh.tftpl", {
    volume_id        = aws_ebs_volume.data.id
    wb_cloud_version = var.wb_cloud_version != null ? var.wb_cloud_version : "latest"
    wb_cloud_ref     = var.wb_cloud_ref != null ? var.wb_cloud_ref : ""
    wb_cloud_repo    = var.wb_cloud_repo
    # Where bootstrap.sh itself is read from: the ref under test, the release
    # tag, or main.
    bootstrap_ref       = coalesce(var.wb_cloud_ref, var.wb_cloud_version != null ? "v${var.wb_cloud_version}" : "main")
    letsencrypt_staging = var.letsencrypt_staging ? "1" : ""
    secret_id           = aws_secretsmanager_secret.this.id
    region              = data.aws_region.current.name
    env                 = local.env
  })
}

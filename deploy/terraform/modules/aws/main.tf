locals {
  hosts        = ["", "*.", "*.ssh.", "*.http.", "*.apps."]
  use_acme     = var.tls_mode == "letsencrypt-dns"
  new_vpc      = var.vpc_id == ""
  vpc_id       = local.new_vpc ? aws_vpc.this[0].id : var.vpc_id
  subnet_id    = local.new_vpc ? aws_subnet.this[0].id : var.subnet_id
  zone_id      = var.hosted_zone_id != "" ? var.hosted_zone_id : (var.create_dns ? aws_route53_zone.this[0].zone_id : "")
  az           = var.availability_zone != "" ? var.availability_zone : data.aws_availability_zones.this.names[0]
  ami          = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.ami[0].value
  public_ports = { https = 443, tunnels = 7107 }
  admin_ports = merge(
    length(var.admin_cidrs) > 0 ? { ssh = 22 } : {},
    var.enable_tunnel_dashboard && length(var.admin_cidrs) > 0 ? { dashboard = 7501 } : {},
  )
  admin_rules = flatten([
    for k, port in local.admin_ports : [for c in var.admin_cidrs : { key = "${k}-${c}", port = port, cidr = c }]
  ])
}

check "dns_for_acme" {
  assert {
    condition     = !(local.use_acme && !var.create_dns)
    error_message = "tls_mode=letsencrypt-dns требует create_dns=true (lego пишет TXT в зону Route53) либо tls_mode=provided."
  }
}
check "existing_vpc_needs_subnet" {
  assert {
    condition     = (var.vpc_id == "") == (var.subnet_id == "")
    error_message = "vpc_id и subnet_id задаются вместе (существующая сеть) или обе пусты (создать новую)."
  }
}
check "existing_vpc_needs_zone" {
  assert {
    condition     = var.vpc_id == "" || var.availability_zone != ""
    error_message = "с существующей подсетью укажите availability_zone этой подсети: том данных должен быть в той же зоне."
  }
}

data "aws_availability_zones" "this" {
  state = "available"
}

data "aws_ssm_parameter" "ami" {
  count = var.ami_id == "" ? 1 : 0
  name  = var.ami_ssm_parameter
}

resource "aws_vpc" "this" {
  count                = local.new_vpc ? 1 : 0
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  count  = local.new_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  tags   = { Name = "${var.name}-igw" }
}

resource "aws_subnet" "this" {
  count             = local.new_vpc ? 1 : 0
  vpc_id            = aws_vpc.this[0].id
  cidr_block        = var.subnet_cidr
  availability_zone = local.az
  tags              = { Name = "${var.name}-subnet" }
}

resource "aws_route_table" "this" {
  count  = local.new_vpc ? 1 : 0
  vpc_id = aws_vpc.this[0].id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this[0].id
  }
  tags = { Name = "${var.name}-rt" }
}

resource "aws_route_table_association" "this" {
  count          = local.new_vpc ? 1 : 0
  subnet_id      = aws_subnet.this[0].id
  route_table_id = aws_route_table.this[0].id
}

resource "aws_security_group" "this" {
  name        = "${var.name}-sg"
  description = "On-premise: 443, 7107 всем; 22/7501 только admin_cidrs"
  vpc_id      = local.vpc_id
  tags        = { Name = "${var.name}-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "public" {
  for_each          = local.public_ports
  security_group_id = aws_security_group.this.id
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv4         = "0.0.0.0/0"
  description       = each.key
}

resource "aws_vpc_security_group_ingress_rule" "admin" {
  for_each          = { for r in local.admin_rules : r.key => r }
  security_group_id = aws_security_group.this.id
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  cidr_ipv4         = each.value.cidr
  description       = "admin ${each.value.port}"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.this.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "исходящий весь"
}

# --- DNS ---
resource "aws_route53_zone" "this" {
  count = var.create_dns && var.hosted_zone_id == "" ? 1 : 0
  name  = var.domain
}

resource "aws_route53_record" "a" {
  for_each = var.create_dns ? toset(local.hosts) : toset([])
  zone_id  = local.zone_id
  name     = "${each.value}${var.domain}"
  type     = "A"
  ttl      = 300
  records  = [aws_eip.this.public_ip]
}

# --- IAM: lego route53 берёт ключи из роли инстанса, в user-data секретов AWS нет ---
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "dns" {
  count = local.use_acme ? 1 : 0
  statement {
    actions   = ["route53:ListHostedZonesByName", "route53:GetChange"]
    resources = ["*"]
  }
  statement {
    actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
    resources = ["arn:aws:route53:::hostedzone/${local.zone_id}"]
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
}

resource "aws_iam_role_policy" "dns" {
  count  = local.use_acme ? 1 : 0
  name   = "${var.name}-route53-acme"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.dns[0].json
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-profile"
  role = aws_iam_role.this.name
}

module "user_data" {
  source            = "../user-data"
  absolute_server   = var.domain
  admin_email       = var.admin_email
  admin_password    = var.admin_password
  onprem_version    = var.onprem_version
  tls_mode          = var.tls_mode
  acme_email        = var.acme_email
  acme_dns_provider = local.use_acme ? "route53" : ""
  acme_env          = local.use_acme ? { AWS_REGION = data.aws_region.this.region, AWS_HOSTED_ZONE_ID = local.zone_id } : {}
  tls_fullchain_pem = var.tls_fullchain_pem
  tls_privkey_pem   = var.tls_privkey_pem
  email_enabled     = var.email_enabled
  email_settings    = var.email_settings
  extra_env         = var.extra_env
}

data "aws_region" "this" {}

resource "aws_key_pair" "this" {
  key_name   = "${var.name}-key"
  public_key = var.ssh_public_key
}

resource "aws_eip" "this" {
  domain = "vpc"
  tags   = { Name = "${var.name}-eip" }
}

resource "aws_instance" "this" {
  ami                    = local.ami
  instance_type          = var.instance_type
  subnet_id              = local.subnet_id
  availability_zone      = local.az
  vpc_security_group_ids = [aws_security_group.this.id]
  key_name               = aws_key_pair.this.key_name
  iam_instance_profile   = aws_iam_instance_profile.this.name
  user_data              = module.user_data.user_data
  # user-data с паролем администратора — не отдавать через IMDSv1 (SSRF)
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device {
    volume_size = var.boot_disk_gb
    volume_type = "gp3"
    encrypted   = true
  }
  tags       = { Name = var.name }
  depends_on = [aws_internet_gateway.this]
}

resource "aws_ebs_volume" "data" {
  availability_zone = local.az
  size              = var.data_disk_gb
  type              = "gp3"
  encrypted         = true
  tags              = { Name = "${var.name}-data" }
}

resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.this.id
}

resource "aws_eip_association" "this" {
  instance_id   = aws_instance.this.id
  allocation_id = aws_eip.this.id
}

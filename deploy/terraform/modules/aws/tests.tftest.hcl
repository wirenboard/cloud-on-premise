mock_provider "aws" {
  mock_data "aws_ssm_parameter" { defaults = { value = "ami-ubuntu2404" } }
  mock_data "aws_availability_zones" { defaults = { names = ["eu-central-1a", "eu-central-1b"] } }
  mock_data "aws_region" { defaults = { region = "eu-central-1" } }
  mock_data "aws_iam_policy_document" { defaults = { json = "{}" } }
  mock_resource "aws_eip" { defaults = { public_ip = "203.0.113.10" } }
  mock_resource "aws_route53_zone" { defaults = { zone_id = "Z123" } }
}

variables {
  domain         = "cloud.example.com"
  admin_email    = "a@example.com"
  admin_password = "Kx7-q9.Lm2wR!"
  ssh_public_key = "ssh-ed25519 AAAA test"
  acme_email     = "ops@example.com"
  create_dns     = true
}

run "defaults_sg_and_sizes" {
  command = plan
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.admin) == 0 && join(",", sort([for r in aws_vpc_security_group_ingress_rule.public : tostring(r.from_port)])) == "443,7107"
    error_message = "без admin_cidrs открыты только 443 и 7107"
  }
  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.public : r.cidr_ipv4 == "0.0.0.0/0" && r.ip_protocol == "tcp" && r.from_port == r.to_port])
    error_message = "публичные правила — один порт tcp"
  }
  assert {
    condition     = aws_ebs_volume.data.size == 100 && aws_ebs_volume.data.encrypted && aws_instance.this.instance_type == "m6i.xlarge" && aws_instance.this.ami == "ami-ubuntu2404"
    error_message = "диск данных, шифрование, тип ВМ или AMI"
  }
  assert {
    condition     = aws_instance.this.metadata_options[0].http_tokens == "required" && aws_instance.this.root_block_device[0].encrypted
    error_message = "IMDSv2 обязателен, корневой диск зашифрован"
  }
  assert {
    condition     = length(aws_route53_record.a) == 5 && length(aws_vpc.this) == 1 && aws_ebs_volume.data.availability_zone == "eu-central-1a"
    error_message = "пять A-записей, новая VPC, зона по умолчанию"
  }
}

run "ssh_and_dashboard_only_for_admin" {
  command = plan
  variables {
    admin_cidrs             = ["198.51.100.7/32", "198.51.100.8/32"]
    enable_tunnel_dashboard = true
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.admin) == 4
    error_message = "22 и 7501 × 2 адреса"
  }
  assert {
    condition     = alltrue([for r in aws_vpc_security_group_ingress_rule.admin : startswith(r.cidr_ipv4, "198.51.100.") && contains([22, 7501], r.from_port)])
    error_message = "22/7501 только для admin_cidrs"
  }
}

run "dashboard_without_cidrs_stays_closed" {
  command = plan
  variables {
    enable_tunnel_dashboard = true
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.admin) == 0
    error_message = "7501 без admin_cidrs не открывать никому"
  }
}

run "user_data_has_variables_and_no_aws_keys" {
  command = plan
  assert {
    condition     = strcontains(aws_instance.this.user_data, "ABSOLUTE_SERVER='cloud.example.com'") && strcontains(aws_instance.this.user_data, "route53") && strcontains(aws_instance.this.user_data, "AWS_REGION") && strcontains(aws_instance.this.user_data, "ADMIN_PASSWORD='Kx7-q9.Lm2wR!'")
    error_message = "user-data без домена, route53, региона или с неэкранированным паролем"
  }
  assert {
    condition     = !strcontains(aws_instance.this.user_data, "AWS_ACCESS_KEY_ID") && !strcontains(aws_instance.this.user_data, "AWS_SECRET_ACCESS_KEY")
    error_message = "ключей AWS в user-data быть не должно (роль инстанса)"
  }
  assert {
    condition     = length(aws_iam_role_policy.dns) == 1
    error_message = "политика route53 для lego"
  }
}

run "existing_vpc_is_reused" {
  command = plan
  variables {
    vpc_id            = "vpc-1"
    subnet_id         = "subnet-1"
    availability_zone = "eu-central-1b"
  }
  assert {
    condition     = length(aws_vpc.this) == 0 && length(aws_subnet.this) == 0 && aws_instance.this.subnet_id == "subnet-1" && aws_ebs_volume.data.availability_zone == "eu-central-1b"
    error_message = "существующая сеть не пересоздаётся"
  }
}

run "existing_zone_not_created" {
  command = plan
  variables {
    hosted_zone_id = "ZEXIST"
  }
  assert {
    condition     = length(aws_route53_zone.this) == 0 && length(aws_route53_record.a) == 5 && alltrue([for r in aws_route53_record.a : r.zone_id == "ZEXIST"])
    error_message = "записи в существующей зоне, новая не создаётся"
  }
}

run "explicit_ami_skips_ssm" {
  command = plan
  variables {
    ami_id = "ami-custom"
  }
  assert {
    condition     = aws_instance.this.ami == "ami-custom" && length(data.aws_ssm_parameter.ami) == 0
    error_message = "ami_id имеет приоритет над SSM"
  }
}

run "acme_requires_dns" {
  command = plan
  variables {
    create_dns = false
  }
  expect_failures = [check.dns_for_acme]
}

run "vpc_without_subnet_rejected" {
  command = plan
  variables {
    vpc_id = "vpc-1"
  }
  expect_failures = [check.existing_vpc_needs_subnet, check.existing_vpc_needs_zone]
}

run "provided_cert_without_dns_ok" {
  command = plan
  variables {
    create_dns        = false
    tls_mode          = "provided"
    tls_fullchain_pem = "CERT"
    tls_privkey_pem   = "KEY"
  }
  assert {
    condition     = length(aws_route53_record.a) == 0 && length(aws_iam_role_policy.dns) == 0 && !strcontains(aws_instance.this.user_data, "route53")
    error_message = "DNS не создаётся, lego и политика не настраиваются"
  }
}

run "weak_admin_password_rejected" {
  command = plan
  variables { admin_password = "change-me" }
  expect_failures = [var.admin_password]
}

run "slash_hash_admin_password_rejected" {
  command = plan
  variables { admin_password = "Kx7/q9#Lm?2wR" }
  expect_failures = [var.admin_password]
}

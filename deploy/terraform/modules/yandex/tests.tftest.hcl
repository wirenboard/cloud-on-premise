mock_provider "yandex" {
  mock_data "yandex_compute_image" { defaults = { id = "fd8image" } }
  mock_resource "yandex_vpc_address" {
    defaults = { external_ipv4_address = { address = "203.0.113.10" } }
  }
}

variables {
  folder_id      = "b1gfolder"
  domain         = "cloud.example.com"
  admin_email    = "a@example.com"
  admin_password = "x'y z"
  ssh_public_key = "ssh-ed25519 AAAA test"
  acme_email     = "ops@example.com"
  create_dns     = true
}

run "defaults_sg_and_sizes" {
  command = plan
  assert {
    condition     = length(yandex_vpc_security_group.this.ingress) == 2 && alltrue([for r in yandex_vpc_security_group.this.ingress : contains([443, 7107], r.port)])
    error_message = "без admin_cidrs открыты только 443 и 7107"
  }
  assert {
    condition     = yandex_compute_disk.data.size == 100 && yandex_compute_instance.this.platform_id == "standard-v3"
    error_message = "размер диска данных или платформа"
  }
  assert {
    condition     = length(yandex_dns_recordset.a) == 5
    error_message = "пять A-записей"
  }
}

run "ssh_and_dashboard_only_for_admin" {
  command = plan
  variables {
    admin_cidrs             = ["198.51.100.7/32"]
    enable_tunnel_dashboard = true
  }
  assert {
    condition     = length(yandex_vpc_security_group.this.ingress) == 4
    error_message = "22 и 7501 появляются только с admin_cidrs"
  }
  assert {
    condition     = alltrue([for r in yandex_vpc_security_group.this.ingress : r.port == 443 || r.port == 7107 || (!contains(r.v4_cidr_blocks, "0.0.0.0/0") && contains(r.v4_cidr_blocks, "198.51.100.7/32"))])
    error_message = "22/7501 только для admin_cidrs"
  }
}

run "dashboard_without_cidrs_stays_closed" {
  command = plan
  variables {
    enable_tunnel_dashboard = true
  }
  assert {
    condition     = length(yandex_vpc_security_group.this.ingress) == 2
    error_message = "7501 без admin_cidrs не открывать никому"
  }
}

run "user_data_has_variables" {
  command = plan
  assert {
    condition     = strcontains(yandex_compute_instance.this.metadata["user-data"], "ABSOLUTE_SERVER='cloud.example.com'") && strcontains(yandex_compute_instance.this.metadata["user-data"], "YANDEX_CLOUD_FOLDER_ID") && strcontains(yandex_compute_instance.this.metadata["user-data"], "x'\\''y z")
    error_message = "user-data без домена, каталога или с неэкранированным паролем"
  }
}

run "acme_requires_dns" {
  command = plan
  variables {
    create_dns = false
  }
  expect_failures = [check.dns_for_acme]
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
    condition     = length(yandex_dns_recordset.a) == 0
    error_message = "DNS не создаётся"
  }
}

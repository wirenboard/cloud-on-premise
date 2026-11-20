mock_provider "openstack" {
  mock_data "openstack_images_image_v2" { defaults = { id = "img-ubuntu" } }
  mock_data "openstack_networking_network_v2" { defaults = { id = "net-ext" } }
  mock_resource "openstack_networking_floatingip_v2" { defaults = { address = "203.0.113.10" } }
}
mock_provider "selectel" {}

variables {
  project_id     = "proj1"
  domain         = "cloud.example.com"
  admin_email    = "a@example.com"
  admin_password = "Kx7-q9.Lm2wR!"
  ssh_public_key = "ssh-ed25519 AAAA test"
  acme_email     = "ops@example.com"
  create_dns     = true
  acme_dns_credentials = {
    SELECTELV2_USERNAME   = "svc"
    SELECTELV2_PASSWORD   = "p"
    SELECTELV2_ACCOUNT_ID = "123"
    SELECTELV2_PROJECT_ID = "proj1"
  }
}

run "defaults_sg_and_sizes" {
  command = plan
  assert {
    condition     = length(openstack_networking_secgroup_rule_v2.admin) == 0 && join(",", sort([for r in openstack_networking_secgroup_rule_v2.public : tostring(r.port_range_min)])) == "443,7107"
    error_message = "без admin_cidrs открыты только 443 и 7107"
  }
  assert {
    condition     = alltrue([for r in openstack_networking_secgroup_rule_v2.public : r.remote_ip_prefix == "0.0.0.0/0" && r.protocol == "tcp"])
    error_message = "публичные правила — tcp"
  }
  assert {
    condition     = openstack_blockstorage_volume_v3.data.size == 100 && openstack_blockstorage_volume_v3.data.volume_type == "fast.ru-3a" && openstack_compute_instance_v2.this.flavor_name == "SL1.4-8192"
    error_message = "диск данных, тип тома или конфигурация"
  }
  assert {
    condition     = length(selectel_domains_rrset_v2.a) == 5
    error_message = "пять A-записей"
  }
}

run "ssh_and_dashboard_only_for_admin" {
  command = plan
  variables {
    admin_cidrs             = ["198.51.100.7/32", "198.51.100.8/32"]
    enable_tunnel_dashboard = true
  }
  assert {
    condition     = length(openstack_networking_secgroup_rule_v2.admin) == 4
    error_message = "22 и 7501 × 2 адреса"
  }
  assert {
    condition     = alltrue([for r in openstack_networking_secgroup_rule_v2.admin : startswith(r.remote_ip_prefix, "198.51.100.") && contains([22, 7501], r.port_range_min)])
    error_message = "22/7501 только для admin_cidrs"
  }
}

run "dashboard_without_cidrs_stays_closed" {
  command = plan
  variables {
    enable_tunnel_dashboard = true
  }
  assert {
    condition     = length(openstack_networking_secgroup_rule_v2.admin) == 0
    error_message = "7501 без admin_cidrs не открывать никому"
  }
}

run "user_data_has_variables" {
  command = plan
  assert {
    condition     = strcontains(openstack_compute_instance_v2.this.user_data, "ABSOLUTE_SERVER='cloud.example.com'") && strcontains(openstack_compute_instance_v2.this.user_data, "SELECTELV2_ACCOUNT_ID") && strcontains(openstack_compute_instance_v2.this.user_data, "selectelv2") && strcontains(openstack_compute_instance_v2.this.user_data, "ADMIN_PASSWORD='Kx7-q9.Lm2wR!'")
    error_message = "user-data без домена, ключей DNS или с неэкранированным паролем"
  }
}

run "acme_requires_dns" {
  command = plan
  variables {
    create_dns = false
  }
  expect_failures = [check.dns_for_acme]
}

run "acme_requires_credentials" {
  command = plan
  variables {
    acme_dns_credentials = {}
  }
  expect_failures = [check.acme_credentials]
}

run "provided_cert_without_dns_ok" {
  command = plan
  variables {
    create_dns           = false
    tls_mode             = "provided"
    tls_fullchain_pem    = "CERT"
    tls_privkey_pem      = "KEY"
    acme_dns_credentials = {}
  }
  assert {
    condition     = length(selectel_domains_rrset_v2.a) == 0 && !strcontains(openstack_compute_instance_v2.this.user_data, "selectelv2")
    error_message = "DNS не создаётся, lego не настраивается"
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

locals {
  zone_name = var.dns_zone != "" ? var.dns_zone : "${var.domain}."
  hosts     = ["", "*.", "*.ssh.", "*.http.", "*.apps."]
  use_acme  = var.tls_mode == "letsencrypt-dns"
  volume    = "${var.volume_type}.${var.availability_zone}"
  # порты, открытые всему миру; остальные — только admin_cidrs
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
    error_message = "tls_mode=letsencrypt-dns требует create_dns=true (lego пишет TXT в зону Selectel DNS) либо tls_mode=provided."
  }
}
check "acme_credentials" {
  assert {
    condition     = !local.use_acme || alltrue([for k in ["SELECTELV2_USERNAME", "SELECTELV2_PASSWORD", "SELECTELV2_ACCOUNT_ID", "SELECTELV2_PROJECT_ID"] : contains(keys(var.acme_dns_credentials), k)])
    error_message = "для letsencrypt-dns задайте acme_dns_credentials: SELECTELV2_USERNAME/PASSWORD/ACCOUNT_ID/PROJECT_ID (сервисный пользователь с ролью работы с DNS)."
  }
}

data "openstack_images_image_v2" "ubuntu" {
  name        = var.image_name
  most_recent = true
}

data "openstack_networking_network_v2" "external" {
  name     = var.external_network
  external = true
}

resource "openstack_networking_network_v2" "this" {
  name = "${var.name}-net"
}

resource "openstack_networking_subnet_v2" "this" {
  name            = "${var.name}-subnet"
  network_id      = openstack_networking_network_v2.this.id
  cidr            = var.subnet_cidr
  ip_version      = 4
  dns_nameservers = var.dns_nameservers
}

resource "openstack_networking_router_v2" "this" {
  name                = "${var.name}-router"
  external_network_id = data.openstack_networking_network_v2.external.id
}

resource "openstack_networking_router_interface_v2" "this" {
  router_id = openstack_networking_router_v2.this.id
  subnet_id = openstack_networking_subnet_v2.this.id
}

resource "openstack_networking_floatingip_v2" "this" {
  pool = var.external_network
}

resource "openstack_networking_secgroup_v2" "this" {
  name                 = "${var.name}-sg"
  description          = "On-premise: 443, 7107 всем; 22/7501 только admin_cidrs"
  delete_default_rules = true # убираем исходящее по умолчанию и пересоздаём ниже явно
}

resource "openstack_networking_secgroup_rule_v2" "public" {
  for_each          = local.public_ports
  security_group_id = openstack_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.value
  port_range_max    = each.value
  remote_ip_prefix  = "0.0.0.0/0"
  description       = each.key
}

resource "openstack_networking_secgroup_rule_v2" "admin" {
  for_each          = { for r in local.admin_rules : r.key => r }
  security_group_id = openstack_networking_secgroup_v2.this.id
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = each.value.port
  port_range_max    = each.value.port
  remote_ip_prefix  = each.value.cidr
  description       = "admin ${each.value.port}"
}

resource "openstack_networking_secgroup_rule_v2" "egress" {
  security_group_id = openstack_networking_secgroup_v2.this.id
  direction         = "egress"
  ethertype         = "IPv4"
  remote_ip_prefix  = "0.0.0.0/0"
  description       = "исходящий весь"
}

module "user_data" {
  source            = "../user-data"
  absolute_server   = var.domain
  admin_email       = var.admin_email
  admin_password    = var.admin_password
  onprem_version    = var.onprem_version
  tls_mode          = var.tls_mode
  acme_email        = var.acme_email
  acme_dns_provider = local.use_acme ? "selectelv2" : ""
  acme_env          = local.use_acme ? var.acme_dns_credentials : {}
  tls_fullchain_pem = var.tls_fullchain_pem
  tls_privkey_pem   = var.tls_privkey_pem
  email_enabled     = var.email_enabled
  email_settings    = var.email_settings
  extra_env         = var.extra_env
}

resource "openstack_compute_keypair_v2" "this" {
  name       = "${var.name}-key"
  public_key = var.ssh_public_key
}

resource "openstack_blockstorage_volume_v3" "boot" {
  name              = "${var.name}-boot"
  size              = var.boot_disk_gb
  image_id          = data.openstack_images_image_v2.ubuntu.id
  volume_type       = local.volume
  availability_zone = var.availability_zone
}

resource "openstack_blockstorage_volume_v3" "data" {
  name              = "${var.name}-data"
  size              = var.data_disk_gb
  volume_type       = local.volume
  availability_zone = var.availability_zone
}

resource "openstack_networking_port_v2" "this" {
  name               = "${var.name}-port"
  network_id         = openstack_networking_network_v2.this.id
  security_group_ids = [openstack_networking_secgroup_v2.this.id]
  fixed_ip {
    subnet_id = openstack_networking_subnet_v2.this.id
  }
}

resource "openstack_compute_instance_v2" "this" {
  name              = var.name
  flavor_name       = var.flavor_name
  key_pair          = openstack_compute_keypair_v2.this.name
  availability_zone = var.availability_zone
  user_data         = module.user_data.user_data

  block_device {
    uuid                  = openstack_blockstorage_volume_v3.boot.id
    source_type           = "volume"
    destination_type      = "volume"
    boot_index            = 0
    delete_on_termination = true
  }
  network {
    port = openstack_networking_port_v2.this.id
  }
  depends_on = [openstack_networking_router_interface_v2.this]
}

resource "openstack_compute_volume_attach_v2" "data" {
  instance_id = openstack_compute_instance_v2.this.id
  volume_id   = openstack_blockstorage_volume_v3.data.id
}

resource "openstack_networking_floatingip_associate_v2" "this" {
  floating_ip = openstack_networking_floatingip_v2.this.address
  port_id     = openstack_networking_port_v2.this.id
  depends_on  = [openstack_networking_router_interface_v2.this]
}

resource "selectel_domains_zone_v2" "this" {
  count      = var.create_dns ? 1 : 0
  name       = local.zone_name
  project_id = var.project_id
}

resource "selectel_domains_rrset_v2" "a" {
  for_each   = var.create_dns ? toset(local.hosts) : toset([])
  zone_id    = selectel_domains_zone_v2.this[0].id
  project_id = var.project_id
  name       = "${each.value}${var.domain}."
  type       = "A"
  ttl        = 300
  records {
    content = openstack_networking_floatingip_v2.this.address
  }
}

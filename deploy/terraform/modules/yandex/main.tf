locals {
  zone_name = var.dns_zone != "" ? var.dns_zone : "${var.domain}."
  # letsencrypt-dns без своей DNS-зоны в Yandex не сработает: lego кладёт TXT в зону этого каталога
  use_yc_dns = var.tls_mode == "letsencrypt-dns"
  hosts      = ["", "*.", "*.ssh.", "*.http.", "*.apps."]
  admin_src  = var.admin_cidrs
}

check "dns_for_acme" {
  assert {
    condition     = !(local.use_yc_dns && !var.create_dns)
    error_message = "tls_mode=letsencrypt-dns требует create_dns=true (lego пишет TXT в зону Yandex Cloud DNS) либо tls_mode=provided."
  }
}

data "yandex_compute_image" "ubuntu" {
  family = var.image_family
}

resource "yandex_vpc_network" "this" {
  name      = "${var.name}-net"
  folder_id = var.folder_id
}

resource "yandex_vpc_subnet" "this" {
  name           = "${var.name}-subnet"
  folder_id      = var.folder_id
  zone           = var.zone
  network_id     = yandex_vpc_network.this.id
  v4_cidr_blocks = [var.subnet_cidr]
}

resource "yandex_vpc_address" "this" {
  name      = "${var.name}-ip"
  folder_id = var.folder_id
  external_ipv4_address {
    zone_id = var.zone
  }
}

resource "yandex_vpc_security_group" "this" {
  name       = "${var.name}-sg"
  folder_id  = var.folder_id
  network_id = yandex_vpc_network.this.id

  ingress {
    description    = "HTTPS (веб, API, публичные туннели)"
    protocol       = "TCP"
    port           = 443
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description    = "Туннели контроллеров (frps)"
    protocol       = "TCP"
    port           = 7107
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
  dynamic "ingress" {
    for_each = length(local.admin_src) > 0 ? [1] : []
    content {
      description    = "SSH только с admin_cidrs"
      protocol       = "TCP"
      port           = 22
      v4_cidr_blocks = local.admin_src
    }
  }
  dynamic "ingress" {
    for_each = var.enable_tunnel_dashboard && length(local.admin_src) > 0 ? [1] : []
    content {
      description    = "Дашборд туннелей только с admin_cidrs"
      protocol       = "TCP"
      port           = 7501
      v4_cidr_blocks = local.admin_src
    }
  }
  egress {
    description    = "Исходящий весь"
    protocol       = "ANY"
    v4_cidr_blocks = ["0.0.0.0/0"]
  }
}

# сервисный аккаунт ВМ: lego берёт IAM-токен из метаданных и пишет TXT в DNS каталога
resource "yandex_iam_service_account" "vm" {
  name      = "${var.name}-vm"
  folder_id = var.folder_id
}

resource "yandex_resourcemanager_folder_iam_member" "dns_editor" {
  count     = var.create_dns ? 1 : 0
  folder_id = var.folder_id
  role      = "dns.editor"
  member    = "serviceAccount:${yandex_iam_service_account.vm.id}"
}

module "user_data" {
  source            = "../user-data"
  absolute_server   = var.domain
  admin_email       = var.admin_email
  admin_password    = var.admin_password
  onprem_version    = var.onprem_version
  tls_mode          = var.tls_mode
  acme_email        = var.acme_email
  acme_dns_provider = var.tls_mode == "letsencrypt-dns" ? "yandexcloud" : ""
  acme_env          = var.tls_mode == "letsencrypt-dns" ? { YANDEX_CLOUD_FOLDER_ID = var.folder_id } : {}
  tls_fullchain_pem = var.tls_fullchain_pem
  tls_privkey_pem   = var.tls_privkey_pem
  email_enabled     = var.email_enabled
  email_settings    = var.email_settings
  extra_env         = var.extra_env
}

resource "yandex_compute_disk" "data" {
  name      = "${var.name}-data"
  folder_id = var.folder_id
  zone      = var.zone
  type      = "network-ssd"
  size      = var.data_disk_gb
}

resource "yandex_compute_instance" "this" {
  name                      = var.name
  folder_id                 = var.folder_id
  zone                      = var.zone
  platform_id               = var.platform_id
  service_account_id        = yandex_iam_service_account.vm.id
  allow_stopping_for_update = true

  resources {
    cores  = var.cores
    memory = var.memory_gb
  }
  boot_disk {
    initialize_params {
      image_id = data.yandex_compute_image.ubuntu.id
      size     = var.boot_disk_gb
      type     = "network-ssd"
    }
  }
  secondary_disk {
    disk_id     = yandex_compute_disk.data.id
    device_name = "onprem-data"
    auto_delete = false
  }
  network_interface {
    subnet_id          = yandex_vpc_subnet.this.id
    nat                = true
    nat_ip_address     = yandex_vpc_address.this.external_ipv4_address[0].address
    security_group_ids = [yandex_vpc_security_group.this.id]
  }
  metadata = {
    user-data = module.user_data.user_data
    ssh-keys  = "ubuntu:${var.ssh_public_key}"
  }
}

resource "yandex_dns_zone" "this" {
  count     = var.create_dns ? 1 : 0
  name      = "${var.name}-zone"
  folder_id = var.folder_id
  zone      = local.zone_name
  public    = true
}

resource "yandex_dns_recordset" "a" {
  for_each = var.create_dns ? toset(local.hosts) : toset([])
  zone_id  = yandex_dns_zone.this[0].id
  name     = "${each.value}${var.domain}."
  type     = "A"
  ttl      = 300
  data     = [yandex_vpc_address.this.external_ipv4_address[0].address]
}

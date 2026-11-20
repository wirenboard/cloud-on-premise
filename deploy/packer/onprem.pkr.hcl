# Образ Wiren Board On-Premise: Ubuntu 24.04 + Docker + код выпуска + предзагруженные образы контейнеров.
# В образе нет домена, паролей и сертификатов — при первой загрузке их приносит user-data (тот же, что у Terraform-модулей),
# install-onprem.sh видит запечённое и пропускает установку Docker и скачивание образов.
#
#   packer init .
#   packer build -only='qemu.onprem'        -var onprem_version=v2.0.1 .      # локально, проверка
#   packer build -only='yandex.onprem'      -var yc_folder_id=... -var yc_subnet_id=... .
#   packer build -only='amazon-ebs.onprem'  .
packer {
  required_plugins {
    qemu   = { source = "github.com/hashicorp/qemu", version = ">= 1.1.0" }
    yandex = { source = "github.com/hashicorp/yandex", version = ">= 1.1.1" }
    amazon = { source = "github.com/hashicorp/amazon", version = ">= 1.3.0" }
  }
}

variable "onprem_version" {
  type        = string
  default     = "v2.0.1"
  description = "Git-тег выпуска cloud-on-premise (v + файл VERSION)"
}
variable "onprem_repo_url" {
  type    = string
  default = "https://github.com/wirenboard/cloud-on-premise.git"
}
variable "image_name" {
  type    = string
  default = ""
}
# qemu
variable "qemu_base_image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}
variable "qemu_base_image_checksum" {
  type        = string
  default     = "file:https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
  description = "Для офлайн-сборки — sha256:<hex> и qemu_base_image_url=file:///путь"
}
variable "qemu_accelerator" {
  type    = string
  default = "kvm"
}
variable "qemu_headless" {
  type    = bool
  default = true
}
variable "qemu_disk_size" {
  type    = string
  default = "30G"
}
variable "qemu_skip_compaction" {
  type        = bool
  default     = false
  description = "true — не пережимать qcow2 (нужно мало места на диске сборки; файл больше)"
}
variable "qemu_output_dir" {
  type    = string
  default = "output-onprem-qemu"
}
# Yandex Cloud
variable "yc_folder_id" {
  type    = string
  default = ""
}
variable "yc_subnet_id" {
  type    = string
  default = ""
}
variable "yc_zone" {
  type    = string
  default = "ru-central1-a"
}
variable "yc_token" {
  type      = string
  default   = ""
  sensitive = true
}
# AWS
variable "aws_region" {
  type    = string
  default = "eu-central-1"
}

locals {
  name = var.image_name != "" ? var.image_name : "wb-onprem-${replace(trimprefix(var.onprem_version, "v"), ".", "-")}"
  bake_env = [
    "ONPREM_BAKE=1",
    "ONPREM_VERSION=${var.onprem_version}",
    "ONPREM_REPO_URL=${var.onprem_repo_url}",
  ]
}

source "qemu" "onprem" {
  iso_url          = var.qemu_base_image_url
  iso_checksum     = var.qemu_base_image_checksum
  disk_image       = true
  disk_size        = var.qemu_disk_size
  disk_compression = !var.qemu_skip_compaction
  skip_compaction  = var.qemu_skip_compaction
  format           = "qcow2"
  accelerator      = var.qemu_accelerator
  headless         = var.qemu_headless
  cpus             = 2
  memory           = 4096
  net_device       = "virtio-net"
  disk_interface   = "virtio"
  output_directory = var.qemu_output_dir
  vm_name          = "${local.name}.qcow2"
  ssh_username     = "packer"
  ssh_password     = "packer-build-only"
  ssh_timeout      = "10m"
  shutdown_command = "sudo -S bash -c 'userdel -rf packer; rm -f /etc/sudoers.d/90-cloud-init-users; shutdown -P now'"
  # NoCloud-источник: создаёт пользователя только на время сборки (пароль не остаётся в образе, см. cleanup.sh)
  cd_label = "cidata"
  cd_content = {
    "meta-data" = "instance-id: packer-build\nlocal-hostname: packer\n"
    "user-data" = <<-UD
      #cloud-config
      ssh_pwauth: true
      users:
        - name: packer
          groups: [sudo]
          shell: /bin/bash
          sudo: "ALL=(ALL) NOPASSWD:ALL"
          lock_passwd: false
          plain_text_passwd: packer-build-only
    UD
  }
}

source "yandex" "onprem" {
  token               = var.yc_token
  folder_id           = var.yc_folder_id
  zone                = var.yc_zone
  subnet_id           = var.yc_subnet_id
  use_ipv4_nat        = true
  source_image_family = "ubuntu-2404-lts-oslogin"
  image_name          = local.name
  image_family        = "wb-onprem"
  image_description   = "Wiren Board On-Premise ${var.onprem_version}"
  disk_size_gb        = 30
  disk_type           = "network-ssd"
  platform_id         = "standard-v3"
  instance_cores      = 2
  instance_mem_gb     = 4
  ssh_username        = "ubuntu"
  image_labels        = { onprem_version = replace(trimprefix(var.onprem_version, "v"), ".", "-") }
}

source "amazon-ebs" "onprem" {
  region          = var.aws_region
  instance_type   = "t3.medium"
  ssh_username    = "ubuntu"
  ami_name        = local.name
  ami_description = "Wiren Board On-Premise ${var.onprem_version}"
  source_ami_filter {
    filters = {
      name                = "ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"
      root-device-type    = "ebs"
      virtualization-type = "hvm"
    }
    owners      = ["099720109477"] # Canonical
    most_recent = true
  }
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
  }
  tags = { Name = local.name, onprem_version = var.onprem_version }
}

build {
  sources = ["source.qemu.onprem", "source.yandex.onprem", "source.amazon-ebs.onprem"]

  provisioner "shell" {
    inline = [
      "sudo cloud-init status --wait || true",
      "sudo mkdir -p /usr/local/sbin",
    ]
  }
  provisioner "file" {
    source      = "${path.root}/../cloud-init/install-onprem.sh"
    destination = "/tmp/install-onprem.sh"
  }
  provisioner "shell" {
    environment_vars = local.bake_env
    execute_command  = "sudo -E bash -c '{{ .Vars }} bash {{ .Path }}'"
    inline = [
      "install -m 0755 /tmp/install-onprem.sh /usr/local/sbin/install-onprem.sh",
      "ONPREM_LOG=/var/log/onprem-bake.log /usr/local/sbin/install-onprem.sh",
    ]
  }
  provisioner "shell" {
    execute_command = "sudo -E bash {{ .Path }}"
    script          = "${path.root}/cleanup.sh"
  }
}

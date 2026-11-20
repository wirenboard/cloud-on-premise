terraform {
  required_version = ">= 1.6"
  required_providers {
    yandex = { source = "yandex-cloud/yandex", version = ">= 0.250" }
  }
}

variable "token" {
  description = "OAuth/IAM-токен или оставьте пусто и задайте YC_TOKEN"
  type        = string
  default     = null
  sensitive   = true
}
variable "cloud_id" { type = string }
variable "folder_id" { type = string }
variable "domain" { type = string }
variable "admin_email" { type = string }
variable "admin_password" {
  type      = string
  sensitive = true
}
variable "ssh_public_key" { type = string }
variable "admin_cidrs" {
  type    = list(string)
  default = []
}
variable "acme_email" { type = string }

provider "yandex" {
  token     = var.token
  cloud_id  = var.cloud_id
  folder_id = var.folder_id
}

module "onprem" {
  source         = "../../modules/yandex"
  folder_id      = var.folder_id
  domain         = var.domain
  admin_email    = var.admin_email
  admin_password = var.admin_password
  ssh_public_key = var.ssh_public_key
  admin_cidrs    = var.admin_cidrs
  acme_email     = var.acme_email
  create_dns     = true
}

output "public_ip" { value = module.onprem.public_ip }
output "dns_records" { value = module.onprem.dns_records }
output "url" { value = module.onprem.url }

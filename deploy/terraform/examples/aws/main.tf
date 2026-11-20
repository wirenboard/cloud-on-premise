terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
  }
}

variable "region" {
  type    = string
  default = "eu-central-1"
}
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
variable "hosted_zone_id" {
  description = "ID существующей зоны Route53, уже делегированной на AWS; пусто — модуль создаст новую зону (см. deploy/README.md, AWS)"
  type        = string
  default     = ""
}

# ключи AWS — из окружения (AWS_PROFILE или AWS_ACCESS_KEY_ID/AWS_SECRET_ACCESS_KEY), в файлы не пишем
provider "aws" {
  region = var.region
}

module "onprem" {
  source         = "../../modules/aws"
  domain         = var.domain
  admin_email    = var.admin_email
  admin_password = var.admin_password
  ssh_public_key = var.ssh_public_key
  admin_cidrs    = var.admin_cidrs
  acme_email     = var.acme_email
  create_dns     = true
  hosted_zone_id = var.hosted_zone_id
}

output "public_ip" { value = module.onprem.public_ip }
output "name_servers" { value = module.onprem.name_servers }
output "dns_records" { value = module.onprem.dns_records }
output "url" { value = module.onprem.url }

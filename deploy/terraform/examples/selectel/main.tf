terraform {
  required_version = ">= 1.6"
  required_providers {
    openstack = { source = "terraform-provider-openstack/openstack", version = ">= 3.0" }
    selectel  = { source = "selectel/selectel", version = ">= 9.0" }
  }
}

variable "selectel_domain_name" {
  description = "Номер аккаунта Selectel (или задайте OS_USER_DOMAIN_NAME/SEL_*)"
  type        = string
}
variable "selectel_username" { type = string }
variable "selectel_password" {
  type      = string
  sensitive = true
}
variable "region" {
  type    = string
  default = "ru-3"
}
variable "project_id" { type = string }
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
variable "acme_dns_credentials" {
  type      = map(string)
  sensitive = true
}

provider "selectel" {
  domain_name = var.selectel_domain_name
  username    = var.selectel_username
  password    = var.selectel_password
  auth_region = var.region
  auth_url    = "https://cloud.api.selcloud.ru/identity/v3/"
}

provider "openstack" {
  auth_url    = "https://cloud.api.selcloud.ru/identity/v3"
  domain_name = var.selectel_domain_name
  tenant_id   = var.project_id
  user_name   = var.selectel_username
  password    = var.selectel_password
  region      = var.region
}

module "onprem" {
  source               = "../../modules/selectel"
  project_id           = var.project_id
  availability_zone    = "${var.region}a"
  domain               = var.domain
  admin_email          = var.admin_email
  admin_password       = var.admin_password
  ssh_public_key       = var.ssh_public_key
  admin_cidrs          = var.admin_cidrs
  acme_email           = var.acme_email
  acme_dns_credentials = var.acme_dns_credentials
  create_dns           = true
}

output "public_ip" { value = module.onprem.public_ip }
output "dns_records" { value = module.onprem.dns_records }
output "url" { value = module.onprem.url }

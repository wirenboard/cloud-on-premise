variable "name" {
  description = "Префикс имён ресурсов"
  type        = string
  default     = "wb-onprem"
}
variable "domain" {
  description = "Основной домен установки (ABSOLUTE_SERVER), например cloud.example.com"
  type        = string
}
variable "admin_email" { type = string }
variable "admin_password" {
  type      = string
  sensitive = true
}
variable "ssh_public_key" {
  description = "Публичный ключ для пользователя ubuntu"
  type        = string
}
variable "admin_cidrs" {
  description = "Адреса, с которых разрешён SSH (22). Пусто — SSH закрыт."
  type        = list(string)
  default     = []
}
variable "enable_tunnel_dashboard" {
  description = "Открыть 7501 (дашборд туннелей) для admin_cidrs"
  type        = bool
  default     = false
}
variable "vpc_id" {
  description = "Существующая VPC. Пусто — создаётся новая (vpc_cidr)."
  type        = string
  default     = ""
}
variable "subnet_id" {
  description = "Существующая публичная подсеть (обязательна вместе с vpc_id)"
  type        = string
  default     = ""
}
variable "vpc_cidr" {
  type    = string
  default = "10.77.0.0/16"
}
variable "subnet_cidr" {
  type    = string
  default = "10.77.0.0/24"
}
variable "availability_zone" {
  description = "Зона для новой подсети и тома данных, например eu-central-1a. Пусто — первая доступная (только при новой VPC)."
  type        = string
  default     = ""
}
variable "instance_type" {
  description = "4 vCPU / 16 ГБ, x86-64 (требование проекта — x86-64-v2, не Graviton)"
  type        = string
  default     = "m6i.xlarge"
}
variable "ami_id" {
  description = "AMI Ubuntu 24.04 amd64. Пусто — берётся из публичного SSM-параметра Canonical (ami_ssm_parameter)."
  type        = string
  default     = ""
}
variable "ami_ssm_parameter" {
  type    = string
  default = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}
variable "boot_disk_gb" {
  type    = number
  default = 30
}
variable "data_disk_gb" {
  type    = number
  default = 100
}
variable "create_dns" {
  description = "Создать публичную зону Route53 и пять A-записей (домен делегируйте на name_servers из вывода)"
  type        = bool
  default     = false
}
variable "hosted_zone_id" {
  description = "Существующая зона Route53: записи создаются в ней, новая зона не создаётся (имеет смысл при create_dns=true)"
  type        = string
  default     = ""
}
variable "tls_mode" {
  type    = string
  default = "letsencrypt-dns"
}
variable "acme_email" {
  type    = string
  default = ""
}
variable "tls_fullchain_pem" {
  type    = string
  default = ""
}
variable "tls_privkey_pem" {
  type      = string
  default   = ""
  sensitive = true
}
variable "onprem_version" {
  type    = string
  default = "v2.0.1"
}
variable "email_enabled" {
  type    = bool
  default = false
}
variable "email_settings" {
  type      = map(string)
  default   = {}
  sensitive = true
}
variable "extra_env" {
  type    = map(string)
  default = {}
}

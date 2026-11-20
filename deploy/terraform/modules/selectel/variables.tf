variable "name" {
  description = "Префикс имён ресурсов"
  type        = string
  default     = "wb-onprem"
}
variable "project_id" {
  description = "ID проекта Selectel (для DNS-зоны)"
  type        = string
}
variable "availability_zone" {
  type    = string
  default = "ru-3a"
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
variable "subnet_cidr" {
  type    = string
  default = "10.77.0.0/24"
}
variable "dns_nameservers" {
  type    = list(string)
  default = ["188.93.16.19", "188.93.17.19"]
}
variable "external_network" {
  description = "Имя внешней сети (пул плавающих адресов)"
  type        = string
  default     = "external-network"
}
variable "flavor_name" {
  description = "Конфигурация ВМ: 4 vCPU / 8 ГБ. Имя вида SL1.4-8192 (в Selectel — стандартная линейка)."
  type        = string
  default     = "SL1.4-8192"
}
variable "image_name" {
  type    = string
  default = "Ubuntu 24.04 LTS 64-bit"
}
variable "boot_disk_gb" {
  type    = number
  default = 30
}
variable "data_disk_gb" {
  type    = number
  default = 100
}
variable "volume_type" {
  description = "Тип тома без зоны; зона добавляется как fast.ru-3a"
  type        = string
  default     = "fast"
}
variable "create_dns" {
  description = "Создать публичную DNS-зону Selectel и пять A-записей (домен делегирован на a/b/c/d.ns.selectel.ru)"
  type        = bool
  default     = false
}
variable "dns_zone" {
  description = "Зона DNS с точкой на конце, по умолчанию — domain + точка"
  type        = string
  default     = ""
}
variable "acme_dns_credentials" {
  description = "Ключи сервисного пользователя Selectel для lego (selectelv2): SELECTELV2_USERNAME, SELECTELV2_PASSWORD, SELECTELV2_ACCOUNT_ID, SELECTELV2_PROJECT_ID"
  type        = map(string)
  default     = {}
  sensitive   = true
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

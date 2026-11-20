variable "name" {
  description = "Префикс имён ресурсов"
  type        = string
  default     = "wb-onprem"
}
variable "folder_id" { type = string }
variable "zone" {
  type    = string
  default = "ru-central1-b"
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
variable "cores" {
  type    = number
  default = 4
}
variable "memory_gb" {
  type    = number
  default = 8
}
variable "boot_disk_gb" {
  type    = number
  default = 30
}
variable "data_disk_gb" {
  type    = number
  default = 100
}
variable "platform_id" {
  description = "Нужен x86-64-v2: standard-v3 (Ice Lake) и новее"
  type        = string
  default     = "standard-v3"
}
variable "image_family" {
  type    = string
  default = "ubuntu-2404-lts"
}
variable "create_dns" {
  description = "Создать публичную DNS-зону и пять A-записей (домен должен быть делегирован на ns1/ns2.yandexcloud.net)"
  type        = bool
  default     = false
}
variable "dns_zone" {
  description = "Зона DNS с точкой на конце (например example.com.), по умолчанию — domain + точка"
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

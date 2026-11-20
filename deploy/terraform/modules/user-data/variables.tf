variable "absolute_server" { type = string }
variable "admin_email" { type = string }
variable "admin_password" {
  type      = string
  sensitive = true
}
variable "onprem_version" {
  type    = string
  default = "v2.0.1"
}
variable "onprem_repo_url" {
  type    = string
  default = "https://github.com/wirenboard/cloud-on-premise.git"
}
variable "tls_mode" {
  type    = string
  default = "letsencrypt-dns"
  validation {
    condition     = contains(["letsencrypt-dns", "provided", "none"], var.tls_mode)
    error_message = "tls_mode: letsencrypt-dns | provided | none."
  }
}
variable "acme_email" {
  type    = string
  default = ""
}
variable "acme_dns_provider" {
  type    = string
  default = ""
}
variable "acme_env" {
  type      = map(string)
  default   = {}
  sensitive = true
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
variable "data_device" {
  type    = string
  default = "auto"
}
variable "email_enabled" {
  type    = bool
  default = false
}
variable "email_settings" {
  description = "EMAIL_HOST, EMAIL_PORT, EMAIL_HOST_USER, EMAIL_HOST_PASSWORD, EMAIL_NOTIFICATIONS_FROM, EMAIL_USE_TLS"
  type        = map(string)
  default     = {}
  sensitive   = true
}
variable "extra_env" {
  description = "Дополнительные переменные .env (например WORKER_CONCURRENCY)"
  type        = map(string)
  default     = {}
}

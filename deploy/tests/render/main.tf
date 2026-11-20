module "ud" {
  source            = "../../terraform/modules/user-data"
  absolute_server   = "cloud.example.com"
  admin_email       = "admin@example.com"
  admin_password    = "p'a ss$w\"d"
  acme_email        = "ops@example.com"
  acme_dns_provider = "yandexcloud"
  acme_env          = { YANDEX_CLOUD_FOLDER_ID = "b1g", YANDEX_CLOUD_IAM_TOKEN = "t$ok'en" }
  email_enabled     = true
  email_settings    = { EMAIL_HOST = "smtp.example.com", EMAIL_PORT = "587", EMAIL_HOST_USER = "u", EMAIL_HOST_PASSWORD = "pw", EMAIL_NOTIFICATIONS_FROM = "n@example.com" }
  extra_env         = { WORKER_CONCURRENCY = "2" }
}
output "user_data" {
  value     = module.ud.user_data
  sensitive = true
}

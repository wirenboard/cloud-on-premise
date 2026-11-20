terraform {
  required_version = ">= 1.6"
}

locals {
  # shell-кавычки: '...' с экранированием одинарной кавычки
  sq = { for k, v in merge(
    {
      ABSOLUTE_SERVER   = var.absolute_server
      ADMIN_EMAIL       = var.admin_email
      ADMIN_PASSWORD    = var.admin_password
      ONPREM_VERSION    = var.onprem_version
      ONPREM_REPO_URL   = var.onprem_repo_url
      TLS_MODE          = var.tls_mode
      ACME_EMAIL        = var.acme_email
      ACME_DNS_PROVIDER = var.acme_dns_provider
      DATA_DEVICE       = var.data_device
      EMAIL_ENABLED     = var.email_enabled ? "True" : "False"
      EXTRA_ENV         = join("\n", [for k, v in var.extra_env : "${k}=${v}"])
    },
    var.email_settings,
  ) : k => "'${replace(v, "'", "'\\''")}'" }

  acme_sq = { for k, v in var.acme_env : k => "'${replace(v, "'", "'\\''")}'" }
}

output "user_data" {
  sensitive = true
  value = templatefile("${path.module}/../../../cloud-init/user-data.yaml.tpl", {
    install_env        = local.sq
    acme_env           = local.acme_sq
    install_script_b64 = base64gzip(file("${path.module}/../../../cloud-init/install-onprem.sh"))
    tls_fullchain_b64  = var.tls_fullchain_pem == "" ? "" : base64encode(var.tls_fullchain_pem)
    tls_privkey_b64    = var.tls_privkey_pem == "" ? "" : base64encode(var.tls_privkey_pem)
  })
}

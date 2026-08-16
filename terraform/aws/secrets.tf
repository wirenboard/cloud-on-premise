# Credentials of the installation, written by the instance after the first
# start — so generated passwords never pass through the Terraform state.
resource "aws_secretsmanager_secret" "this" {
  name                    = "${local.name}/credentials"
  description             = "Wiren Board Cloud on-premise credentials for ${var.domain}"
  recovery_window_in_days = 7
  tags                    = local.tags
}

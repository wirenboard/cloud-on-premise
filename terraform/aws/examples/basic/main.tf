terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 6.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

module "wb_cloud" {
  source = "../../"

  domain          = "cloud.example.com"
  route53_zone_id = "Z0123456789ABCDEFGHIJ"
  admin_email     = "admin@example.com"

  # Pin the release for a reproducible deployment.
  wb_cloud_version = "2.0.0"
}

output "cloud_url" {
  value = module.wb_cloud.cloud_url
}

output "credentials_command" {
  value = module.wb_cloud.credentials_command
}

output "shell_command" {
  value = module.wb_cloud.shell_command
}

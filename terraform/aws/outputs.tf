output "cloud_url" {
  description = "Where the cloud answers once the installation has finished."
  value       = "https://${var.domain}"
}

output "admin_email" {
  description = "Administrator login."
  value       = var.admin_email
}

output "credentials_command" {
  description = "Reads back the credentials the installer generated: administrator, Grafana, tunnel dashboard, database."
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.this.id} --query SecretString --output text --region ${data.aws_region.current.name}"
}

output "shell_command" {
  description = "Shell on the instance without opening port 22. Upgrades are run from there: cd /opt/wb-cloud && make update"
  value       = "aws ssm start-session --target ${aws_instance.this.id} --region ${data.aws_region.current.name}"
}

output "install_log_command" {
  description = "The first installation takes 15-20 minutes; this is where it reports progress."
  value       = "aws ssm start-session --target ${aws_instance.this.id} --region ${data.aws_region.current.name} --document-name AWS-StartInteractiveCommand --parameters command='tail -f /var/log/wb-cloud-install.log'"
}

output "public_ip" {
  description = "Elastic IP the DNS records point at."
  value       = aws_eip.this.public_ip
}

output "instance_id" {
  description = "EC2 instance running the cloud."
  value       = aws_instance.this.id
}

output "data_volume_id" {
  description = "Volume holding the databases. It outlives the instance and is protected from destroy."
  value       = aws_ebs_volume.data.id
}

output "dns_names" {
  description = "Names pointed at the cloud, and the ones the certificate covers."
  value       = local.dns_names
}

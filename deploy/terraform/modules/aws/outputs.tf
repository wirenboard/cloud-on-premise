output "public_ip" { value = aws_eip.this.public_ip }
output "url" { value = "https://${var.domain}" }
output "dns_records" {
  description = "Пять A-записей; если create_dns=false — создайте у своего DNS-хостера"
  value       = [for h in local.hosts : "${h}${var.domain}"]
}
output "name_servers" {
  description = "NS новой зоны Route53 (для делегирования домена); пусто, если зона не создавалась"
  value       = length(aws_route53_zone.this) > 0 ? aws_route53_zone.this[0].name_servers : []
}
output "security_group_id" { value = aws_security_group.this.id }
output "instance_id" { value = aws_instance.this.id }

output "public_ip" { value = yandex_vpc_address.this.external_ipv4_address[0].address }
output "url" { value = "https://${var.domain}" }
output "dns_records" {
  description = "Пять A-записей, если create_dns=false — создайте у своего DNS-хостера"
  value       = [for h in local.hosts : "${h}${var.domain}"]
}
output "security_group_id" { value = yandex_vpc_security_group.this.id }

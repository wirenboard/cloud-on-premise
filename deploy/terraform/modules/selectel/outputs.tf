output "public_ip" { value = openstack_networking_floatingip_v2.this.address }
output "url" { value = "https://${var.domain}" }
output "dns_records" {
  description = "Пять A-записей, если create_dns=false — создайте у своего DNS-хостера"
  value       = [for h in local.hosts : "${h}${var.domain}"]
}
output "security_group_id" { value = openstack_networking_secgroup_v2.this.id }

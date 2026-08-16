# The host plus the wildcards for the per-controller ssh / http / apps
# subdomains — which is why a real DNS zone is a requirement here.
resource "aws_route53_record" "cloud" {
  for_each = toset(local.dns_names)

  zone_id = var.route53_zone_id
  name    = each.value
  type    = "A"
  ttl     = 300
  records = [aws_eip.this.public_ip]
}

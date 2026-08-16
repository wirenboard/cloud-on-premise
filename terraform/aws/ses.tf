# Optional mail for invitations and password resets. A fresh SES account is in
# the sandbox: production access is a support request nobody can automate.

resource "aws_ses_domain_identity" "this" {
  count  = var.enable_ses ? 1 : 0
  domain = var.domain
}

resource "aws_route53_record" "ses_verification" {
  count = var.enable_ses ? 1 : 0

  zone_id = var.route53_zone_id
  name    = "_amazonses.${var.domain}"
  type    = "TXT"
  ttl     = 600
  records = [aws_ses_domain_identity.this[0].verification_token]
}

resource "aws_ses_domain_identity_verification" "this" {
  count = var.enable_ses ? 1 : 0

  domain     = aws_ses_domain_identity.this[0].id
  depends_on = [aws_route53_record.ses_verification]
}

resource "aws_ses_domain_dkim" "this" {
  count  = var.enable_ses ? 1 : 0
  domain = aws_ses_domain_identity.this[0].domain
}

resource "aws_route53_record" "ses_dkim" {
  count = var.enable_ses ? 3 : 0

  zone_id = var.route53_zone_id
  name    = "${aws_ses_domain_dkim.this[0].dkim_tokens[count.index]}._domainkey.${var.domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_ses_domain_dkim.this[0].dkim_tokens[count.index]}.dkim.amazonses.com"]
}

# A custom MAIL FROM keeps bounce handling and SPF on our own domain.
resource "aws_ses_domain_mail_from" "this" {
  count = var.enable_ses ? 1 : 0

  domain           = aws_ses_domain_identity.this[0].domain
  mail_from_domain = "mail.${var.domain}"
}

resource "aws_route53_record" "ses_mail_from_mx" {
  count = var.enable_ses ? 1 : 0

  zone_id = var.route53_zone_id
  name    = aws_ses_domain_mail_from.this[0].mail_from_domain
  type    = "MX"
  ttl     = 600
  records = ["10 feedback-smtp.${data.aws_region.current.name}.amazonses.com"]
}

resource "aws_route53_record" "ses_mail_from_spf" {
  count = var.enable_ses ? 1 : 0

  zone_id = var.route53_zone_id
  name    = aws_ses_domain_mail_from.this[0].mail_from_domain
  type    = "TXT"
  ttl     = 600
  records = ["v=spf1 include:amazonses.com -all"]
}

resource "aws_route53_record" "ses_dmarc" {
  count = var.enable_ses ? 1 : 0

  zone_id = var.route53_zone_id
  name    = "_dmarc.${var.domain}"
  type    = "TXT"
  ttl     = 600
  records = ["v=DMARC1; p=none; rua=mailto:${var.admin_email}"]
}

# SES speaks SMTP through IAM credentials, which is what the cloud's EMAIL_* settings expect.
resource "aws_iam_user" "ses" {
  count = var.enable_ses ? 1 : 0
  name  = "${local.name}-ses"
  tags  = local.tags
}

data "aws_iam_policy_document" "ses" {
  count = var.enable_ses ? 1 : 0

  statement {
    actions   = ["ses:SendRawEmail"]
    resources = ["*"]
  }
}

resource "aws_iam_user_policy" "ses" {
  count = var.enable_ses ? 1 : 0

  name   = "${local.name}-ses"
  user   = aws_iam_user.ses[0].name
  policy = data.aws_iam_policy_document.ses[0].json
}

resource "aws_iam_access_key" "ses" {
  count = var.enable_ses ? 1 : 0
  user  = aws_iam_user.ses[0].name
}

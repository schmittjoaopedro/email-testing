resource "aws_ses_domain_identity" "email_testing" {
  domain = local.email_domain
}

resource "aws_ses_domain_dkim" "email_testing" {
  domain = aws_ses_domain_identity.email_testing.domain
}

resource "aws_ses_domain_mail_from" "email_testing_mail_from" {
  domain           = aws_ses_domain_identity.email_testing.domain
  mail_from_domain = "bounce.${local.email_domain}"
}

resource "aws_route53_record" "dkim_verification_record" {
  count   = 3
  zone_id = local.route53_zone
  type    = "CNAME"
  ttl     = 300
  name    = "${aws_ses_domain_dkim.email_testing.dkim_tokens[count.index]}._domainkey.${local.email_prefix}"
  records = ["${aws_ses_domain_dkim.email_testing.dkim_tokens[count.index]}.dkim.amazonses.com"]
}

resource "aws_route53_record" "email_inbound_mx" {
  zone_id = local.route53_zone
  type    = "MX"
  ttl     = 300
  name    = local.email_domain
  records = ["10 inbound-smtp.${data.aws_region.current.name}.amazonaws.com"]
}

resource "aws_route53_record" "email_inbound_txt" {
  zone_id = local.route53_zone
  type    = "TXT"
  ttl     = 300
  name    = "_dmarc.${local.email_domain}"
  records = ["v=DMARC1; p=none;"]
}


resource "aws_route53_record" "email_testing_bounce_policy" {
  zone_id = local.route53_zone
  type    = "TXT"
  ttl     = 300
  name    = "bounce.${local.email_domain}"
  records = ["v=spf1 include:amazonses.com ~all"]
}

resource "aws_route53_record" "email_testing_bounce_server" {
  zone_id = local.route53_zone
  type    = "MX"
  ttl     = 300
  name    = "bounce.${local.email_domain}"
  records = ["10 feedback-smtp.${data.aws_region.current.name}.amazonses.com"]
}

resource "random_pet" "bucket_name" {
  length = 2
}

resource "aws_s3_bucket" "email_testing" {
  bucket        = "${local.email_prefix}-storage-bucket-${random_pet.bucket_name.id}"
  force_destroy = true
}

resource "aws_s3_bucket_lifecycle_configuration" "email_testing" {
  bucket = aws_s3_bucket.email_testing.bucket

  rule {
    id      = "expire-all-objects"
    status  = "Enabled"

    expiration {
      days = 1
    }
  }
}

resource "aws_s3_bucket_policy" "email_testing" {
  bucket = aws_s3_bucket.email_testing.bucket
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = {
          Service = "ses.amazonaws.com"
        }
        Action    = "s3:PutObject"
        Resource  = "arn:aws:s3:::${aws_s3_bucket.email_testing.bucket}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceAccount" = data.aws_caller_identity.current.account_id
          }
        }
      }
    ]
  })
}

resource "aws_ses_receipt_rule_set" "email_testing_receive_rule_set" {
  rule_set_name = "${local.email_prefix}-receive-rule-set"
}

resource "aws_ses_active_receipt_rule_set" "email_testing_receive_rule_set" {
  rule_set_name = aws_ses_receipt_rule_set.email_testing_receive_rule_set.rule_set_name
}

resource "aws_ses_receipt_rule" "email_testing_receive_rule" {
  name          = "store-all-emails"
  rule_set_name = aws_ses_receipt_rule_set.email_testing_receive_rule_set.rule_set_name
  recipients    = [local.email_domain]
  enabled       = true
  scan_enabled  = false

  s3_action {
    bucket_name = aws_s3_bucket.email_testing.bucket
    position    = 1
  }

  depends_on = [aws_s3_bucket_policy.email_testing]
}


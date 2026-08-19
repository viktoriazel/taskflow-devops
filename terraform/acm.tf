# -----------------------------------------------------------------------------
# ACM certificate for the Jenkins webhook endpoint
#
# HTTPS is required wherever Jenkins is exposed through an Ingress or
# LoadBalancer, and the webhook is the only thing published - the Jenkins UI
# stays unpublished and is reached with kubectl port-forward. So this covers
# exactly one hostname: no wildcard, no apex, no additional SAN. Adding a name
# later means a new certificate rather than an edit, which is cheap; a wildcard
# would put every future subdomain behind one private key for no current gain.
#
# eu-north-1, because an Application Load Balancer is a regional resource and
# accepts only a certificate from its own region. us-east-1 would matter only
# for CloudFront, which this architecture does not use.
#
# The certificate creates no public endpoint on its own: it listens nowhere and
# resolves to nothing. The only DNS record created here points at an ACM
# validation host, not at our infrastructure. The public entry point appears
# later, with the Jenkins Ingress and its ALB.
#
# Note for the security section: issuing a public certificate publishes
# jenkins.taskflow.plus to Certificate Transparency logs, so the name is
# discoverable before the endpoint exists. That is expected and is why the
# webhook is protected by path restriction, GitHub source CIDRs, and a shared
# secret rather than by the name being unknown.
# -----------------------------------------------------------------------------

# Read-only. The hosted zone and the domain registration are managed outside
# this configuration - Terraform never becomes their owner, and `destroy` must
# never be able to remove the zone or the delegation.
data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

resource "aws_acm_certificate" "jenkins" {
  domain_name       = "jenkins.${var.domain_name}"
  validation_method = "DNS"

  tags = merge(local.common_tags, {
    Name = "jenkins.${var.domain_name}"
  })

  # A deliberate lifecycle choice rather than a hard requirement: once this
  # certificate is attached to an ALB listener, ACM refuses to delete it, so a
  # future change that forces a new certificate would fail midway through the
  # apply if Terraform destroyed first. Creating the replacement first keeps
  # that path safe.
  lifecycle {
    create_before_destroy = true
  }
}

# Kept in the configuration permanently, not only until issuance: ACM managed
# renewal works as long as the certificate is in use and this validation CNAME
# stays resolvable.
#
# allow_overwrite is deliberately not set. The zone is not owned by this
# configuration, so an unexpected pre-existing record should surface as a
# failed apply rather than be silently replaced.
resource "aws_route53_record" "jenkins_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.jenkins.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  }

  zone_id = data.aws_route53_zone.main.zone_id
  name    = each.value.name
  type    = each.value.type
  records = [each.value.record]
  ttl     = 60
}

# Not a certificate - a wait. This blocks the apply until ACM reports the
# certificate as issued, so nothing downstream can reference a certificate that
# is not yet usable.
resource "aws_acm_certificate_validation" "jenkins" {
  certificate_arn         = aws_acm_certificate.jenkins.arn
  validation_record_fqdns = [for record in aws_route53_record.jenkins_cert_validation : record.fqdn]
}

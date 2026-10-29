################################################################################
# Server certificate (ACM), covering both host names
################################################################################

resource "aws_acm_certificate" "private" {
  count = var.tls_certificate_source == "acm_private_ca" ? 1 : 0

  domain_name               = var.hostname
  subject_alternative_names = [var.mtls_hostname]
  certificate_authority_arn = var.private_ca_arn
  tags                      = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "public" {
  count = var.tls_certificate_source == "acm_public" ? 1 : 0

  domain_name               = var.hostname
  subject_alternative_names = [var.mtls_hostname]
  validation_method         = "DNS"
  tags                      = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "certificate_validation" {
  for_each = var.tls_certificate_source == "acm_public" ? {
    for o in aws_acm_certificate.public[0].domain_validation_options : o.domain_name => o
  } : {}

  zone_id         = var.route53_zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "public" {
  count = var.tls_certificate_source == "acm_public" ? 1 : 0

  certificate_arn         = aws_acm_certificate.public[0].arn
  validation_record_fqdns = [for r in aws_route53_record.certificate_validation : r.fqdn]
}

locals {
  certificate_arn = (
    var.tls_certificate_source == "acm_private_ca" ? aws_acm_certificate.private[0].arn :
    var.tls_certificate_source == "acm_public" ? aws_acm_certificate_validation.public[0].certificate_arn :
    var.certificate_arn
  )
}

################################################################################
# Security groups
################################################################################

resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Stroom-Proxy ALB: listeners from the NLBs, targets in the cluster"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_nlb" {
  for_each = local.endpoints

  security_group_id            = aws_security_group.alb.id
  description                  = "${each.key} listener from its NLB"
  ip_protocol                  = "tcp"
  from_port                    = each.value.alb_port
  to_port                      = each.value.alb_port
  referenced_security_group_id = aws_security_group.nlb[each.key].id
}

# If the NLB preserves client IPs to its ALB target, traffic reaches the ALB
# from the senders' own addresses (or, over PrivateLink, the NLB's addresses
# in the lb subnets) rather than from the NLB security group. Allow both, so
# it works either way; the ALB is internal and these are the same listeners.
resource "aws_vpc_security_group_ingress_rule" "alb_from_senders" {
  for_each = {
    for pair in setproduct(keys(local.endpoints), distinct(concat(var.allowed_ingress_cidrs, var.lb_subnet_cidrs))) :
    "${pair[0]}/${pair[1]}" => { endpoint = pair[0], cidr = pair[1] }
  }

  security_group_id = aws_security_group.alb.id
  description       = "${each.value.endpoint} listener, client IP preserved by the NLB"
  ip_protocol       = "tcp"
  from_port         = local.endpoints[each.value.endpoint].alb_port
  to_port           = local.endpoints[each.value.endpoint].alb_port
  cidr_ipv4         = each.value.cidr
}

# The plain listener also answers the mTLS NLB's health checks.
resource "aws_vpc_security_group_ingress_rule" "alb_health_from_mtls_nlb" {
  count = local.mtls_enabled ? 1 : 0

  security_group_id            = aws_security_group.alb.id
  description                  = "Health checks from the mTLS NLB"
  ip_protocol                  = "tcp"
  from_port                    = local.endpoints.plain.alb_port
  to_port                      = local.endpoints.plain.alb_port
  referenced_security_group_id = aws_security_group.nlb["mtls"].id
}

resource "aws_vpc_security_group_egress_rule" "alb_to_pods" {
  for_each = local.ports

  security_group_id            = aws_security_group.alb.id
  description                  = "To proxy pods (${each.key})"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = var.node_security_group_id
}

# Pods use the node security group (VPC CNI). The NetworkPolicy further limits
# them to traffic from the lb subnets.
resource "aws_vpc_security_group_ingress_rule" "pods_from_alb" {
  for_each = local.ports

  security_group_id            = var.node_security_group_id
  description                  = "Stroom-Proxy ${each.key} from the ALB"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.alb.id
}

################################################################################
# ALB
################################################################################

resource "aws_lb" "alb" {
  name               = "${local.short_name}-alb"
  load_balancer_type = "application"
  internal           = true
  subnets            = var.lb_subnet_ids
  security_groups    = [aws_security_group.alb.id]
  idle_timeout       = var.alb_idle_timeout

  drop_invalid_header_fields = true
  # Remove X-Forwarded-For rather than append to it: Jetty takes the leftmost
  # entry, which a client could forge (F19). ALB access logs keep the real
  # client addresses.
  xff_header_processing_mode = "remove"

  dynamic "access_logs" {
    for_each = var.alb_access_logs_bucket == null ? [] : [1]
    content {
      bucket  = var.alb_access_logs_bucket
      prefix  = "${var.name}-alb"
      enabled = true
    }
  }

  tags = var.tags
}

resource "aws_wafv2_web_acl_association" "alb" {
  count = var.waf_web_acl_arn == null ? 0 : 1

  resource_arn = aws_lb.alb.arn
  web_acl_arn  = var.waf_web_acl_arn
}

# Client CA bundle from the receipt config bucket (section 5.2). A new PEM
# version is picked up on the next apply, without touching the proxies.
resource "aws_lb_trust_store" "clients" {
  count = local.mtls_enabled ? 1 : 0

  name                                     = "${local.short_name}-clients"
  ca_certificates_bundle_s3_bucket         = local.receipt_config_bucket_name
  ca_certificates_bundle_s3_key            = var.auth.trust_store_pem_s3_key
  ca_certificates_bundle_s3_object_version = local.client_ca_bundle_version
  tags                                     = var.tags
}

resource "aws_lb_trust_store_revocation" "clients" {
  for_each = data.aws_s3_object.client_crl

  trust_store_arn               = aws_lb_trust_store.clients[0].arn
  revocations_s3_bucket         = local.receipt_config_bucket_name
  revocations_s3_key            = each.key
  revocations_s3_object_version = each.value.version_id
}

# One target group per colour; pods are registered by TargetGroupBinding.
resource "aws_lb_target_group" "proxy" {
  for_each = var.proxy_deployments

  name                 = "${local.short_name}-${each.key}"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  protocol             = "HTTPS"
  port                 = local.ports.https
  deregistration_delay = var.deregistration_delay

  health_check {
    protocol            = "HTTP"
    port                = tostring(local.ports.admin)
    path                = local.health_check_path
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = merge(var.tags, { "stroom-proxy/colour" = each.key })
}

locals {
  active_target_group_arn = aws_lb_target_group.proxy[var.active_colour].arn
}

# mTLS listener: the ALB verifies the client certificate and passes its
# subject DN to the proxy in X-Stroom-Mtls-Subject. Only when certificate
# authentication is enabled.
resource "aws_lb_listener" "mtls" {
  count = local.mtls_enabled ? 1 : 0

  load_balancer_arn = aws_lb.alb.arn
  port              = local.endpoints.mtls.alb_port
  protocol          = "HTTPS"
  ssl_policy        = var.alb_ssl_policy
  certificate_arn   = local.certificate_arn

  mutual_authentication {
    mode                             = "verify"
    trust_store_arn                  = aws_lb_trust_store.clients[0].arn
    ignore_client_certificate_expiry = false
  }

  routing_http_request_x_amzn_mtls_clientcert_subject_header_name = local.mtls_subject_header

  default_action {
    type             = "forward"
    target_group_arn = local.active_target_group_arn
  }

  tags = var.tags
}

# Non-mTLS listener: tokens and data feed keys.
resource "aws_lb_listener" "plain" {
  load_balancer_arn = aws_lb.alb.arn
  port              = local.endpoints.plain.alb_port
  protocol          = "HTTPS"
  ssl_policy        = var.alb_ssl_policy
  certificate_arn   = local.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = local.active_target_group_arn
  }

  tags = var.tags
}

# Stop a sender on the non-mTLS listener claiming a certificate identity: the
# proxy trusts the DN header from anyone (F14, section 5.3).
resource "aws_lb_listener_rule" "plain_reject_dn_headers" {
  for_each = {
    for i, header in [local.mtls_subject_header, "X-Amzn-Mtls-Clientcert-Subject", "X-Amzn-Mtls-Clientcert", "X-SSL-CLIENT-S-DN"] :
    header => i + 1
  }

  listener_arn = aws_lb_listener.plain.arn
  priority     = each.value

  condition {
    http_header {
      http_header_name = each.key
      values           = ["*"]
    }
  }

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Client certificate headers are not accepted on this endpoint."
      status_code  = "403"
    }
  }

  tags = var.tags
}

################################################################################
# Test listeners for the inactive colour (blue/green, section 9.2)
#
# A target group only health-checks its targets while a listener uses it.
# Without these, the inactive colour's pods would never pass their readiness
# gates, and adding a second colour would never finish. They also let
# admin_cidrs test the new colour before the switch.
################################################################################

locals {
  inactive_colours = [for c in local.colours : c if c != var.active_colour]
  # Test listener per endpoint (443 -> 9444, 8443 -> 9443), only while a
  # second colour exists.
  test_listeners = length(local.inactive_colours) == 0 ? {} : {
    for k, e in local.endpoints : k => {
      port   = k == "mtls" ? 9443 : 9444
      colour = local.inactive_colours[0]
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_test_from_admins" {
  for_each = {
    for pair in setproduct(keys(local.test_listeners), var.admin_cidrs) :
    "${pair[0]}/${pair[1]}" => { endpoint = pair[0], cidr = pair[1] }
  }

  security_group_id = aws_security_group.alb.id
  description       = "Test listener (${each.value.endpoint}) from admins"
  ip_protocol       = "tcp"
  from_port         = local.test_listeners[each.value.endpoint].port
  to_port           = local.test_listeners[each.value.endpoint].port
  cidr_ipv4         = each.value.cidr
}

resource "aws_lb_listener" "test" {
  for_each = local.test_listeners

  load_balancer_arn = aws_lb.alb.arn
  port              = each.value.port
  protocol          = "HTTPS"
  ssl_policy        = var.alb_ssl_policy
  certificate_arn   = local.certificate_arn

  dynamic "mutual_authentication" {
    for_each = each.key == "mtls" ? [1] : []
    content {
      mode                             = "verify"
      trust_store_arn                  = aws_lb_trust_store.clients[0].arn
      ignore_client_certificate_expiry = false
    }
  }

  routing_http_request_x_amzn_mtls_clientcert_subject_header_name = each.key == "mtls" ? local.mtls_subject_header : null

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.proxy[each.value.colour].arn
  }

  tags = var.tags
}

# Same protection as the plain listener: no DN headers.
resource "aws_lb_listener_rule" "test_plain_reject_dn_headers" {
  for_each = contains(keys(local.test_listeners), "plain") ? {
    for i, header in [local.mtls_subject_header, "X-Amzn-Mtls-Clientcert-Subject", "X-Amzn-Mtls-Clientcert", "X-SSL-CLIENT-S-DN"] :
    header => i + 1
  } : {}

  listener_arn = aws_lb_listener.test["plain"].arn
  priority     = each.value

  condition {
    http_header {
      http_header_name = each.key
      values           = ["*"]
    }
  }

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Client certificate headers are not accepted on this endpoint."
      status_code  = "403"
    }
  }

  tags = var.tags
}

# Health check for the NLBs (they can't use the mTLS listener).
resource "aws_lb_listener_rule" "plain_lb_health" {
  listener_arn = aws_lb_listener.plain.arn
  priority     = 100

  condition {
    path_pattern {
      values = ["/lb-health"]
    }
  }

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "ok"
      status_code  = "200"
    }
  }

  tags = var.tags
}

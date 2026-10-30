################################################################################
# Server certificate (ACM) for the host name, as for the proxy
################################################################################

resource "aws_acm_certificate" "private" {
  count = var.tls_certificate_source == "acm_private_ca" ? 1 : 0

  domain_name               = var.hostname
  certificate_authority_arn = var.private_ca_arn
  tags                      = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_acm_certificate" "public" {
  count = var.tls_certificate_source == "acm_public" ? 1 : 0

  domain_name       = var.hostname
  validation_method = "DNS"
  tags              = var.tags

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

resource "aws_acm_certificate" "imported" {
  count = var.tls_certificate_source == "acm_imported" && nonsensitive(var.imported_certificate != null) ? 1 : 0

  certificate_body  = var.imported_certificate.certificate_pem
  private_key       = var.imported_certificate.private_key_pem
  certificate_chain = var.imported_certificate.certificate_chain_pem
  tags              = var.tags

  lifecycle {
    create_before_destroy = true
  }
}

locals {
  certificate_arn = (
    var.tls_certificate_source == "acm_private_ca" ? aws_acm_certificate.private[0].arn :
    var.tls_certificate_source == "acm_public" ? aws_acm_certificate_validation.public[0].certificate_arn :
    var.tls_certificate_source == "acm_imported" ? one(aws_acm_certificate.imported[*].arn) :
    var.certificate_arn
  )
}

################################################################################
# Security groups
################################################################################

resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-stroom-alb-"
  description = "Stroom ALB: HTTPS from users, targets in the cluster"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-stroom-alb" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  for_each = toset(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from users"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  for_each = toset(var.allowed_ingress_cidrs)

  security_group_id = aws_security_group.alb.id
  description       = "HTTP from users, redirected to HTTPS"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "alb_to_pods" {
  for_each = local.ports

  security_group_id            = aws_security_group.alb.id
  description                  = "To Stroom pods (${each.key})"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = var.node_security_group_id
}

# Pods use the node security group (VPC CNI); the NetworkPolicy narrows it
resource "aws_vpc_security_group_ingress_rule" "pods_from_alb" {
  for_each = local.ports

  security_group_id            = var.node_security_group_id
  description                  = "Stroom ${each.key} from the Stroom ALB"
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  referenced_security_group_id = aws_security_group.alb.id
}

################################################################################
# ALB (design section 9)
################################################################################

resource "aws_lb" "stroom" {
  name               = "${local.short_name}-stroom"
  load_balancer_type = "application"
  internal           = true
  subnets            = var.lb_subnet_ids
  security_groups    = [aws_security_group.alb.id]
  idle_timeout       = var.alb_idle_timeout

  drop_invalid_header_fields = true
  xff_header_processing_mode = "remove"

  depends_on = [terraform_data.input_checks]

  dynamic "access_logs" {
    for_each = var.alb_access_logs_bucket == null ? [] : [1]
    content {
      bucket  = var.alb_access_logs_bucket
      prefix  = "${var.name}-stroom-alb"
      enabled = true
    }
  }

  tags = var.tags
}

# The Frontend node set's pods, registered by TargetGroupBinding. HTTPS to the
# pods (design 9.1); the ALB doesn't check their certificates.
resource "aws_lb_target_group" "ui" {
  name                 = "${local.short_name}-stroom-ui"
  vpc_id               = var.vpc_id
  target_type          = "ip"
  protocol             = "HTTPS"
  port                 = local.ports.https
  deregistration_delay = 60

  health_check {
    protocol            = "HTTP"
    port                = tostring(local.ports.admin)
    path                = "/stroomAdmin/ping"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  # A UI session lives on one node (S13)
  stickiness {
    enabled     = true
    type        = "app_cookie"
    cookie_name = "STROOM_SESSION_ID"
  }

  tags = var.tags
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.stroom.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.alb_ssl_policy
  certificate_arn   = local.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui.arn
  }

  tags = var.tags
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.stroom.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"
    redirect {
      protocol    = "HTTPS"
      port        = "443"
      status_code = "HTTP_301"
    }
  }

  tags = var.tags
}

# Cluster calls between nodes go pod to pod, never through the ALB (S13); data
# comes through the proxy and S3, not Stroom's own datafeed (design 9)
resource "aws_lb_listener_rule" "refuse" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  condition {
    path_pattern {
      values = ["*clustercall.rpc*", "/datafeed*", "/stroom/datafeed*", "/stroom/noauth/datafeed*", "/api/datafeed*"]
    }
  }

  action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Forbidden"
      status_code  = "403"
    }
  }

  tags = var.tags
}

resource "aws_route53_record" "hostname" {
  count = var.route53_zone_id == null ? 0 : 1

  zone_id = var.route53_zone_id
  name    = var.hostname
  type    = "A"

  alias {
    name                   = aws_lb.stroom.dns_name
    zone_id                = aws_lb.stroom.zone_id
    evaluate_target_health = false
  }
}

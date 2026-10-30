################################################################################
# Two NLBs, one per endpoint, each forwarding 443 to its ALB listener, each
# with its own VPC endpoint service (section 5.1, 5.4).
################################################################################

locals {
  internet_facing = var.load_balancer_scheme == "internet-facing"
  nlb_subnet_ids  = local.internet_facing ? var.public_subnet_ids : var.lb_subnet_ids
}

resource "aws_security_group" "nlb" {
  for_each = local.endpoints

  name_prefix = "${var.name}-nlb-${each.key}-"
  description = "Stroom-Proxy ${each.key} NLB: senders on 443, forwarding to the ALB"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-nlb-${each.key}" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "nlb_from_senders" {
  for_each = {
    for pair in setproduct(keys(local.endpoints), var.allowed_ingress_cidrs) :
    "${pair[0]}/${pair[1]}" => { endpoint = pair[0], cidr = pair[1] }
  }

  security_group_id = aws_security_group.nlb[each.value.endpoint].id
  description       = "Senders"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value.cidr
}

resource "aws_vpc_security_group_egress_rule" "nlb_to_alb" {
  for_each = local.endpoints

  security_group_id            = aws_security_group.nlb[each.key].id
  description                  = "To the ALB ${each.key} listener"
  ip_protocol                  = "tcp"
  from_port                    = each.value.alb_port
  to_port                      = each.value.alb_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_vpc_security_group_egress_rule" "nlb_health_to_alb" {
  count = local.mtls_enabled ? 1 : 0

  security_group_id            = aws_security_group.nlb["mtls"].id
  description                  = "Health checks to the ALB plain listener"
  ip_protocol                  = "tcp"
  from_port                    = local.endpoints.plain.alb_port
  to_port                      = local.endpoints.plain.alb_port
  referenced_security_group_id = aws_security_group.alb.id
}

resource "aws_lb" "nlb" {
  for_each = local.endpoints

  name               = "${local.short_name}-nlb-${each.key}"
  load_balancer_type = "network"
  internal           = !local.internet_facing
  subnets            = local.nlb_subnet_ids
  security_groups    = [aws_security_group.nlb[each.key].id]

  enable_cross_zone_load_balancing = true
  # PrivateLink access is controlled by the endpoint service's allowed
  # principals and acceptance; senders' addresses there are unknown.
  enforce_security_group_inbound_rules_on_private_link_traffic = "off"

  tags = var.tags
}

resource "aws_lb_target_group" "nlb_to_alb" {
  for_each = local.endpoints

  name        = "${local.short_name}-alb-${each.key}"
  vpc_id      = var.vpc_id
  target_type = "alb"
  protocol    = "TCP"
  # Must match the ALB listener port.
  port = each.value.alb_port

  # Through the ALB's plain listener for both NLBs: the mTLS listener would
  # refuse the health checker, which has no client certificate.
  health_check {
    protocol            = "HTTPS"
    port                = tostring(local.endpoints.plain.alb_port)
    path                = "/lb-health"
    matcher             = "200"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = var.tags
}

resource "aws_lb_target_group_attachment" "nlb_to_alb" {
  for_each = local.endpoints

  target_group_arn = aws_lb_target_group.nlb_to_alb[each.key].arn
  target_id        = aws_lb.alb.arn
  port             = each.value.alb_port

  # The ALB must have a listener on the port before it can be a target.
  depends_on = [aws_lb_listener.plain, aws_lb_listener.mtls]
}

resource "aws_lb_listener" "nlb" {
  for_each = local.endpoints

  load_balancer_arn = aws_lb.nlb[each.key].arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.nlb_to_alb[each.key].arn
  }

  tags = var.tags
}

################################################################################
# PrivateLink: one endpoint service per NLB
################################################################################

resource "aws_vpc_endpoint_service" "proxy" {
  for_each = var.privatelink.enabled ? local.endpoints : {}

  network_load_balancer_arns = [aws_lb.nlb[each.key].arn]
  acceptance_required        = var.privatelink.acceptance_required
  allowed_principals         = var.privatelink.allowed_principals
  # Senders use the same host name over PrivateLink, so the certificate matches.
  private_dns_name = each.value.hostname

  tags = merge(var.tags, { Name = "${var.name}-${each.key}" })
}

# AWS verifies ownership of each private DNS name with a TXT record.
resource "aws_route53_record" "privatelink_verification" {
  for_each = var.privatelink.enabled && var.privatelink.verification_zone_id != null ? local.endpoints : {}

  zone_id = var.privatelink.verification_zone_id
  name    = "${aws_vpc_endpoint_service.proxy[each.key].private_dns_name_configuration[0].name}.${each.value.hostname}"
  type    = "TXT"
  ttl     = 300
  records = [aws_vpc_endpoint_service.proxy[each.key].private_dns_name_configuration[0].value]
}

################################################################################
# DNS
################################################################################

resource "aws_route53_record" "endpoint" {
  for_each = var.route53_zone_id == null ? {} : local.endpoints

  zone_id = var.route53_zone_id
  name    = each.value.hostname
  type    = "A"

  alias {
    name                   = aws_lb.nlb[each.key].dns_name
    zone_id                = aws_lb.nlb[each.key].zone_id
    evaluate_target_health = true
  }
}

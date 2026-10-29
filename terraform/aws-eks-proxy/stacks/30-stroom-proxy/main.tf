data "terraform_remote_state" "infra" {
  backend = "s3"
  config  = var.infra_state
}

data "terraform_remote_state" "platform" {
  backend = "s3"
  config  = var.platform_state
}

locals {
  infra    = data.terraform_remote_state.infra.outputs
  platform = data.terraform_remote_state.platform.outputs

  tags = merge(
    {
      Project   = "stroom-proxy"
      Stack     = "30-stroom-proxy"
      Cluster   = local.infra.cluster_name
      ManagedBy = "terraform"
    },
    var.tags,
  )
}

module "stroom_proxy" {
  source = "../../modules/stroom-proxy"

  # From 10-infra and 20-platform.
  name                   = local.infra.name
  cluster_name           = local.infra.cluster_name
  aws_region             = local.infra.aws_region
  vpc_id                 = local.infra.vpc_id
  vpc_cidr               = local.infra.vpc_cidr
  lb_subnet_ids          = local.infra.lb_subnet_ids
  lb_subnet_cidrs        = local.infra.lb_subnet_cidrs
  public_subnet_ids      = local.infra.public_subnet_ids
  node_security_group_id = local.infra.node_security_group_id
  proxy_node_colours = {
    for c, v in local.infra.proxy_node_colours : c => {
      node_label = v.node_label
      node_count = v.node_count
    }
  }
  secrets_name_prefix = local.platform.secrets_name_prefix
  storage_class_name  = local.platform.storage_class_name

  admin_principal_arns = var.admin_principal_arns
  tags                 = var.tags

  namespace         = var.namespace
  chart_repository  = var.chart_repository
  chart_version     = var.chart_version
  chart_path        = var.chart_path
  proxy_deployments = var.proxy_deployments
  active_colour     = var.active_colour

  proxy_resources      = var.proxy_resources
  proxy_java_opts      = var.proxy_java_opts
  proxy_data_volume_gb = var.proxy_data_volume_gb
  proxy_id_prefix      = var.proxy_id_prefix

  load_balancer_scheme   = var.load_balancer_scheme
  allowed_ingress_cidrs  = var.allowed_ingress_cidrs
  admin_cidrs            = var.admin_cidrs
  hostname               = var.hostname
  mtls_hostname          = var.mtls_hostname
  route53_zone_id        = var.route53_zone_id
  tls_certificate_source = var.tls_certificate_source
  private_ca_arn         = var.private_ca_arn
  certificate_arn        = var.certificate_arn
  alb_ssl_policy         = var.alb_ssl_policy
  alb_idle_timeout       = var.alb_idle_timeout
  deregistration_delay   = var.deregistration_delay
  alb_access_logs_bucket = var.alb_access_logs_bucket
  waf_web_acl_arn        = var.waf_web_acl_arn
  privatelink            = var.privatelink

  auth                      = var.auth
  receipt_config_bucket     = var.receipt_config_bucket
  dfk_sync_interval_seconds = var.dfk_sync_interval_seconds
  downstream                = var.downstream
  receipt                   = var.receipt

  data_bucket_name            = var.data_bucket_name
  data_bucket_kms_key_arn     = var.data_bucket_kms_key_arn
  data_retention_days         = var.data_retention_days
  data_expire_after_retention = var.data_expire_after_retention
  data_notifications          = var.data_notifications
  forward_s3                  = var.forward_s3
  aggregation                 = var.aggregation
  extra_proxy_config          = var.extra_proxy_config
}

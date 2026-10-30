data "terraform_remote_state" "infra" {
  backend = "s3"
  config  = var.infra_state
}

locals {
  infra = data.terraform_remote_state.infra.outputs

  tags = merge(
    {
      Project   = "stroom-proxy"
      Stack     = "20-platform"
      Cluster   = local.infra.cluster_name
      ManagedBy = "terraform"
    },
    var.tags,
  )
}

module "platform" {
  source = "../../modules/platform"

  cluster_name      = local.infra.cluster_name
  aws_region        = local.infra.aws_region
  vpc_id            = local.infra.vpc_id
  system_node_label = local.infra.system_node_label

  lb_controller_chart_version = var.lb_controller_chart_version

  gp3_iops        = var.gp3_iops
  gp3_throughput  = var.gp3_throughput
  ebs_kms_key_arn = var.ebs_kms_key_arn

  cloudwatch_addon_version = var.cloudwatch_addon_version
  log_retention_days       = var.log_retention_days
  log_kms_key_arn          = var.log_kms_key_arn

  external_secrets_chart_version = var.external_secrets_chart_version
  secrets_name_prefix            = coalesce(var.secrets_name_prefix, "stroom-proxy/${local.infra.name}/")

  # Stroom's components only when 10-infra has Stroom node groups. try() for a
  # 10-infra state written before the output existed.
  stroom_enabled               = length(try(local.infra.stroom_node_sets, {})) > 0
  cert_manager_chart_version   = var.cert_manager_chart_version
  trust_manager_chart_version  = var.trust_manager_chart_version
  metrics_server_chart_version = var.metrics_server_chart_version
  stroom_operator              = var.stroom_operator
}

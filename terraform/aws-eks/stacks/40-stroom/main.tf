data "terraform_remote_state" "infra" {
  backend = "s3"
  config  = var.infra_state
}

data "terraform_remote_state" "platform" {
  backend = "s3"
  config  = var.platform_state
}

# The proxy in this cluster, whose data bucket Stroom ingests from (design 4.3)
data "terraform_remote_state" "proxy" {
  count   = var.proxy_state == null ? 0 : 1
  backend = "s3"
  config  = var.proxy_state
}

locals {
  infra    = data.terraform_remote_state.infra.outputs
  platform = data.terraform_remote_state.platform.outputs
  proxy    = var.proxy_state == null ? null : data.terraform_remote_state.proxy[0].outputs

  # From the proxy's stack, or for a bucket managed elsewhere from ingest (design
  # 4.4). try(): a proxy state from before these outputs lacks them, and
  # stack_checks says so, rather than an "Unsupported attribute" error here.
  ingest = local.proxy == null ? var.ingest : {
    bucket            = try(local.proxy.data_bucket, null)
    queue_url         = try(local.proxy.data_events_queue_url, null)
    queue_arn         = try(local.proxy.data_events_queue_arn, null)
    dlq_url           = try(local.proxy.data_events_dlq_url, null)
    dlq_arn           = try(local.proxy.data_events_dlq_arn, null)
    kms_key_arn       = try(local.proxy.data_bucket_kms_key_arn, null)
    expire_after_days = try(local.proxy.data_expire_after_days, null)
  }

  imported_certificate = var.imported_certificate_files == null ? null : {
    certificate_pem       = file(var.imported_certificate_files.certificate)
    private_key_pem       = sensitive(file(var.imported_certificate_files.private_key))
    certificate_chain_pem = var.imported_certificate_files.certificate_chain == null ? null : file(var.imported_certificate_files.certificate_chain)
  }

  tags = merge(
    {
      Project   = "stroom"
      Stack     = "40-stroom"
      Cluster   = local.infra.cluster_name
      ManagedBy = "terraform"
    },
    var.tags,
  )
}

resource "terraform_data" "stack_checks" {
  lifecycle {
    precondition {
      condition     = length(try(local.infra.stroom_node_sets, {})) > 0 && try(local.platform.stroom_enabled, false)
      error_message = "The cluster has no Stroom node groups, or 20-platform hasn't installed Stroom's components: set stroom_node_sets in 10-infra and apply 10-infra and 20-platform first."
    }

    precondition {
      condition = local.proxy != null || alltrue([
        for k in ["bucket", "queue_url", "queue_arn", "dlq_url", "dlq_arn"] : lookup(var.ingest, k, null) != null
      ])
      error_message = "Without proxy_state, ingest needs bucket, queue_url, queue_arn, dlq_url and dlq_arn: the data bucket Stroom reads (design 4.4)."
    }

    # data_retention_days is always set by a proxy stack new enough for
    # 40-stroom (data_expire_after_days may be null, and a null output isn't
    # kept in state, so it can't tell an old state from no expiry)
    precondition {
      condition = local.proxy == null || (
        try(local.proxy.data_retention_days, null) != null &&
        alltrue([for k in ["namespace", "data_bucket", "data_events_queue_url", "data_events_queue_arn", "data_events_dlq_url", "data_events_dlq_arn"] : try(local.proxy[k], null) != null])
      )
      error_message = "The proxy stack has no data events queue (its data_notifications must be \"sqs\"), or its state predates the outputs 40-stroom reads (data_events_queue_arn, data_events_dlq_url, data_events_dlq_arn, data_retention_days, ...): apply 30-stroom-proxy first."
    }
  }
}

# The CA bundle that signs RDS certificates in this region: Stroom, the
# operator and the init Job verify the database's certificate with it
data "http" "rds_ca_bundle" {
  url = "https://truststore.pki.rds.amazonaws.com/${local.infra.aws_region}/${local.infra.aws_region}-bundle.pem"

  lifecycle {
    postcondition {
      condition     = self.status_code == 200 && strcontains(self.response_body, "BEGIN CERTIFICATE")
      error_message = "Couldn't download the RDS CA bundle for ${local.infra.aws_region}."
    }
  }
}

module "stroom_db" {
  source = "../../modules/stroom-db"

  name                      = local.infra.name
  vpc_id                    = local.infra.vpc_id
  subnet_ids                = local.infra.private_subnet_ids
  client_security_group_ids = [local.infra.node_security_group_id]
  secrets_name_prefix       = local.platform.secrets_name_prefix
  database                  = var.database
  tags                      = var.tags

  depends_on = [terraform_data.stack_checks]
}

module "stroom" {
  source = "../../modules/stroom"

  # From 10-infra and 20-platform
  name                      = local.infra.name
  cluster_name              = local.infra.cluster_name
  aws_region                = local.infra.aws_region
  vpc_id                    = local.infra.vpc_id
  private_subnet_ids        = local.infra.private_subnet_ids
  lb_subnet_ids             = local.infra.lb_subnet_ids
  lb_subnet_cidrs           = local.infra.lb_subnet_cidrs
  node_security_group_id    = local.infra.node_security_group_id
  stroom_node_sets          = { for k, v in try(local.infra.stroom_node_sets, {}) : k => { node_label = v.node_label, node_count = v.node_count } }
  stroom_node_taint         = local.infra.stroom_node_taint
  storage_class_name        = local.platform.storage_class_name
  secrets_name_prefix       = local.platform.secrets_name_prefix
  external_secrets_role_arn = local.platform.external_secrets_role_arn
  internal_ca               = local.platform.internal_ca
  tags                      = var.tags

  db = {
    host                      = module.stroom_db.host
    port                      = module.stroom_db.port
    master_user_secret_arn    = module.stroom_db.master_user_secret_arn
    app_user                  = module.stroom_db.app_user
    app_user_secret_name      = module.stroom_db.app_user_secret_name
    app_user_secret_arn       = module.stroom_db.app_user_secret_arn
    app_user_password_version = module.stroom_db.app_user_password_version
    kms_key_arn               = module.stroom_db.kms_key_arn
    ca_bundle_pem             = data.http.rds_ca_bundle.response_body
  }

  node_name_prefix = var.node_name_prefix
  stroom_image     = var.stroom_image
  stopped          = var.stopped
  node_sets        = var.node_sets
  extra_jvm_opts   = var.extra_jvm_opts
  stream_volume    = var.stream_volume
  idp              = var.idp

  ingest                  = local.ingest
  raw_data_retention_days = var.raw_data_retention_days

  hostname               = var.hostname
  allowed_ingress_cidrs  = var.allowed_ingress_cidrs
  route53_zone_id        = var.route53_zone_id
  tls_certificate_source = var.tls_certificate_source
  private_ca_arn         = var.private_ca_arn
  certificate_arn        = var.certificate_arn
  imported_certificate   = local.imported_certificate
  alb_idle_timeout       = var.alb_idle_timeout
  alb_access_logs_bucket = var.alb_access_logs_bucket

  # The proxy reaches Stroom for receipt rules with its own API key (design 8.1)
  proxy_namespace           = local.proxy == null ? null : try(local.proxy.namespace, null)
  proxy_api_key_secret_name = local.proxy == null ? null : var.proxy_api_key_secret_name

  depends_on = [terraform_data.stack_checks]
}

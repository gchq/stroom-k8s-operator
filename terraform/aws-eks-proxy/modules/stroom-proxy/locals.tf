data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
data "aws_iam_session_context" "current" {
  arn = data.aws_caller_identity.current.arn
}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  # Load balancer and target group names are limited to 32 characters.
  short_name = trimsuffix(substr(var.name, 0, 20), "-")

  # Principals allowed to change Object Lock settings and disable or delete
  # the data key: the configured admins plus whoever runs Terraform.
  lock_admin_arns = distinct(concat(var.admin_principal_arns, [data.aws_iam_session_context.current.issuer_arn]))

  colours = keys(var.proxy_deployments)

  # Names the chart gives each colour's resources ("<chart>-<colour>").
  service_name         = { for c in local.colours : c => "stroom-proxy-${c}" }
  service_account_name = { for c in local.colours : c => "stroom-proxy-${c}" }

  ports = {
    https = 8443
    admin = 8091
  }

  # Same as the chart's healthCheckPath: the downstream and IdP checks are
  # excluded, so pods stay ready while those are down (F15).
  health_check_path = "/proxyAdmin/filteredhealthcheck?minimal=true&deny=stroom.proxy.app.handler.RemoteFeedStatusClient,stroom.proxy.app.ReceiveDataRuleSetClient,stroom.proxy.app.security.ProxyApiKeyCheckClient,stroom.proxy.app.handler.RemoteS3EventClient,stroom.security.common.impl.ExternalIdpConfigurationProvider"

  # DN header the ALB's mTLS listener sets, and the proxy trusts (section 5.2).
  mtls_subject_header = "X-Stroom-Mtls-Subject"

  certificate_types = setintersection(toset(var.auth.types), toset(["CERTIFICATE", "CERTIFICATE_IDENTITY"]))
  mtls_enabled      = length(local.certificate_types) > 0

  # The two endpoints: each has an ALB listener, an NLB and (optionally) a
  # VPC endpoint service. The mTLS one exists only with certificate auth.
  endpoints = merge(
    { plain = { alb_port = 443, hostname = var.hostname } },
    local.mtls_enabled ? { mtls = { alb_port = 8443, hostname = var.mtls_hostname } } : {},
  )
  dfk_enabled = var.auth.dfk_s3_prefix != null && length(setintersection(toset(var.auth.types), toset(["DATA_FEED_KEY", "CERTIFICATE_IDENTITY"]))) > 0

  # Secrets the proxy reads from environment variables, synced from Secrets
  # Manager by External Secrets into one Kubernetes Secret.
  proxy_secrets = merge(
    var.downstream == null ? {} : { DOWNSTREAM_API_KEY = var.downstream.api_key_secret_name },
    try(var.auth.openid.client_secret_name, null) == null ? {} : { OPENID_CLIENT_SECRET = var.auth.openid.client_secret_name },
  )
  proxy_secret_name = "stroom-proxy-secrets"

  ##############################################################################
  # The proxy's proxyConfig, in its own keys (rendered by the chart)
  ##############################################################################

  proxy_config = merge(
    {
      receive = {
        authenticationRequired     = var.auth.required
        enabledAuthenticationTypes = var.auth.types
        receiptCheckMode           = var.receipt.check_mode
        fallbackReceiveAction      = var.receipt.fallback_action
        dataFeedOwnerMetaKey       = var.auth.data_feed_owner_meta_key
        x509CertificateDnHeader    = local.mtls_subject_header
        x509CertificateDnFormat    = "LDAP"
      }
      # Optional parts are built with "for" over a zero- or one-element list
      # and spread into merge(). A conditional between differently shaped
      # objects ("cond ? {} : {...}") makes Terraform convert both to a map
      # of strings, turning booleans and numbers into "false" and "443".
      downstreamHost = merge(
        { enabled = var.downstream != null },
        [for d in var.downstream == null ? [] : [var.downstream] : {
          scheme     = d.scheme
          hostname   = d.hostname
          port       = d.port
          pathPrefix = d.path_prefix
          apiKey     = "$${DOWNSTREAM_API_KEY}"
        }]...
      )
      aggregator = {
        enabled                 = var.aggregation.enabled
        aggregationFrequency    = var.aggregation.frequency
        maxItemsPerAggregate    = var.aggregation.max_items
        maxUncompressedByteSize = var.aggregation.max_uncompressed_size
      }
      forwardS3Destinations = [{
        name = "data-bucket"
        # New objects are announced by S3 event notifications (data_notifications).
        notificationType = "S3_EVENT"
        client = {
          region     = var.aws_region
          bucketName = local.data_bucket_name
          keyPattern = var.forward_s3.key_template
          multipart  = var.forward_s3.multipart
        }
      }]
    },
    [for o in var.auth.openid == null ? [] : [var.auth.openid] : {
      security = {
        authentication = {
          openId = merge(
            {
              identityProviderType = "EXTERNAL_IDP"
              issuer               = o.issuer
              clientId             = o.client_id
              allowedAudiences     = o.allowed_audiences
              uniqueIdentityClaim  = o.unique_identity_claim
            },
            # Single string values: a map of strings is the right type here.
            o.openid_configuration_endpoint == null ? {} : { openIdConfigurationEndpoint = o.openid_configuration_endpoint },
            o.client_secret_name == null ? {} : { clientSecret = "$${OPENID_CLIENT_SECRET}" },
          )
        }
      }
    }]...
  )

  # Helm values for one colour's release. extra_proxy_config is passed as a
  # second values document, which Helm deep-merges over the first.
  helm_values = {
    for c, d in var.proxy_deployments : c => {
      colour   = c
      replicas = d.replicas
      image = {
        tag    = d.image_tag
        digest = d.image_digest
      }
      serviceAccount = {
        create = true
        name   = local.service_account_name[c]
      }
      resources = var.proxy_resources
      javaOpts  = var.proxy_java_opts
      persistence = {
        storageClassName = var.storage_class_name
        size             = "${var.proxy_data_volume_gb}Gi"
      }
      ports           = { https = local.ports.https, admin = local.ports.admin }
      healthCheckPath = local.health_check_path
      drain = {
        deregistrationDelaySeconds = var.deregistration_delay
      }
      dfkSync = {
        enabled         = local.dfk_enabled
        bucket          = local.receipt_config_bucket_name
        prefix          = coalesce(var.auth.dfk_s3_prefix, "dfk/")
        intervalSeconds = var.dfk_sync_interval_seconds
      }
      extraEnvFrom = length(local.proxy_secrets) == 0 ? [] : [{ secretRef = { name = local.proxy_secret_name } }]
      # Each pod's own ID (pod names are unique and stable), e.g.
      # "prod-stroom-proxy-blue-0". Receipt IDs include it.
      proxyConfig = merge(local.proxy_config, { proxyId = "${coalesce(var.proxy_id_prefix, var.name)}-$${POD_NAME}" })
    }
  }
}

# Checks that span several inputs, so they can't be variable validations.
resource "terraform_data" "input_checks" {
  lifecycle {
    precondition {
      condition     = !contains(var.auth.types, "TOKEN") || var.auth.openid != null || var.downstream != null
      error_message = "TOKEN authentication needs auth.openid (OAuth tokens) or downstream (Stroom API keys)."
    }
    precondition {
      condition     = !contains(["FEED_STATUS", "RECEIPT_POLICY", "FEED_EXISTENCE"], var.receipt.check_mode) || var.downstream != null
      error_message = "receipt.check_mode ${var.receipt.check_mode} needs a downstream Stroom."
    }
    precondition {
      condition     = length(setintersection(toset(var.auth.types), toset(["DATA_FEED_KEY", "CERTIFICATE_IDENTITY"]))) == 0 || var.auth.dfk_s3_prefix != null || var.downstream != null
      error_message = "DATA_FEED_KEY and CERTIFICATE_IDENTITY need auth.dfk_s3_prefix (keys from S3) or downstream (keys from Stroom)."
    }
    precondition {
      condition     = !local.mtls_enabled || var.receipt_config_bucket != null || var.auth.client_ca_bundle_pem != null
      error_message = "Certificate authentication needs the client CA bundle: set auth.client_ca_bundle_pem, or receipt_config_bucket to an existing bucket that holds auth.trust_store_pem_s3_key."
    }
    precondition {
      condition     = !var.auth.required ? !contains(var.allowed_ingress_cidrs, "0.0.0.0/0") : true
      error_message = "auth.required = false (anonymous receipt) isn't allowed with 0.0.0.0/0 in allowed_ingress_cidrs."
    }
    precondition {
      condition     = var.load_balancer_scheme == "internal" || (!contains(var.allowed_ingress_cidrs, "0.0.0.0/0") && length(var.public_subnet_ids) >= 2)
      error_message = "An internet-facing NLB needs public subnets and allowed_ingress_cidrs without 0.0.0.0/0."
    }
    precondition {
      condition = (
        var.tls_certificate_source == "acm_private_ca" ? var.private_ca_arn != null :
        var.tls_certificate_source == "acm_public" ? var.route53_zone_id != null :
        var.certificate_arn != null
      )
      error_message = "tls_certificate_source needs its input: private_ca_arn for acm_private_ca, route53_zone_id for acm_public, certificate_arn for acm_existing."
    }
    precondition {
      condition     = alltrue([for c in local.colours : contains(keys(var.proxy_node_colours), c)])
      error_message = "Every colour in proxy_deployments needs proxy nodes of that colour (proxy_node_colours in 10-infra)."
    }
    precondition {
      # One pod per node (required pod anti-affinity).
      condition     = alltrue([for c, d in var.proxy_deployments : !contains(keys(var.proxy_node_colours), c) || d.replicas <= var.proxy_node_colours[c].node_count])
      error_message = "A colour has more replicas than nodes; each proxy needs its own node. Raise nodes_per_az for that colour in 10-infra."
    }
    precondition {
      condition     = !var.privatelink.enabled || length(var.privatelink.allowed_principals) > 0
      error_message = "privatelink.allowed_principals must list who may connect when PrivateLink is enabled."
    }
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  partition  = data.aws_partition.current.partition
  account_id = data.aws_caller_identity.current.account_id

  # Load balancer and target group names are limited to 32 characters.
  short_name = substr(var.name, 0, 20)

  # Names the operator gives things (api/v1/stroomcluster_types.go)
  base_name            = "stroom-${var.cluster_resource_name}"
  service_account_name = local.base_name
  node_set_names       = { for k, s in var.node_sets : k => "${var.node_name_prefix}-${k}" }
  headless_services    = local.node_set_names
  http_services        = { for k, n in local.node_set_names : k => "${n}-http" }

  # The label selecting each node set's nodes. The fallback is the label
  # 10-infra uses, so a node set missing there reaches input_checks' message.
  node_labels = {
    for k in keys(var.node_sets) : k => try(var.stroom_node_sets[k].node_label, { key = "stroom/node-set", value = k })
  }

  # The Frontend node set behind the ALB
  frontend_node_set = sort([for k, s in var.node_sets : k if s.role == "Frontend"])[0]

  ports = {
    https = 8443
    admin = 8081
  }

  image = var.stroom_image.digest == null ? "${var.stroom_image.repository}:${var.stroom_image.tag}" : "${var.stroom_image.repository}:${var.stroom_image.tag}@${var.stroom_image.digest}"

  # Secrets in the namespace
  db_secret_name         = "stroom-db"
  db_master_secret_name  = "stroom-db-master"
  oidc_secret_name       = "stroom-oidc"
  keystore_password_name = "stroom-keystore-password"
  tls_secret_name        = "stroom-tls"
  db_ca_configmap_name   = "rds-ca"
  stream_volume_pvc_name = "stroom-stream"
  stream_volume_path     = "/stroom/stream"
  index_volume_path      = "/stroom/index"
  config_configmap_name  = "stroom-config"
  config_configmap_key   = "config.yml"
  secrets_manager_store  = "secrets-manager"
  generator_name         = "keystore-password"

  # Identity provider presets (design section 8)
  idp_discovery_url = coalesce(
    var.idp.discovery_url,
    var.idp.type == "entra" ? "https://login.microsoftonline.com/${coalesce(var.idp.tenant_id, "none")}/v2.0/.well-known/openid-configuration" : null,
  )
  idp_presets = {
    entra = {
      allowedAudiences     = [var.idp.client_id, "api://${var.idp.client_id}"]
      requestScopes        = ["openid", "email", "profile", "offline_access"]
      uniqueIdentityClaim  = "oid"
      userDisplayNameClaim = "preferred_username"
    }
    keycloak = {
      requestScopes        = ["openid", "email", "profile"]
      uniqueIdentityClaim  = "sub"
      userDisplayNameClaim = "preferred_username"
    }
    cognito = {
      requestScopes         = ["openid", "email", "profile"]
      uniqueIdentityClaim   = "sub"
      userDisplayNameClaim  = "cognito:username"
      audienceClaimRequired = false
      formTokenRequest      = true
    }
  }
  open_id = merge(
    {
      identityProviderType        = "EXTERNAL_IDP"
      openIdConfigurationEndpoint = local.idp_discovery_url
      # Set from the operator's openId settings, which come from the Secret
      clientId     = "$${STROOM_OPERATOR_OPENID_CLIENT_ID}"
      clientSecret = "$${STROOM_OPERATOR_OPENID_CLIENT_SECRET}"
    },
    local.idp_presets[var.idp.type],
  )

  # The operator's StroomCluster names its pods' Pod Identity service account
  # after the cluster; the bootstrap Job has its own
  bootstrap_service_account         = "stroom-bootstrap"
  proxy_key_renewal_service_account = "stroom-proxy-key-renewal"

  # Labels of the bootstrap Job's pods: the NetworkPolicy lets only these, of
  # the pods that aren't Stroom's, reach Stroom's API
  bootstrap_pod_labels = { "app.kubernetes.io/name" = "stroom-bootstrap" }

  # Pod annotations that restart the Stroom nodes (one at a time) when a secret
  # they read only at start has changed: the database user's password
  # (generation from modules/stroom-db) and the TLS certificate (cert-manager's
  # revision, read from the Certificate at plan time)
  restart_annotations = {
    "stroom.gchq.github.io/db-password-version" = tostring(var.db.app_user_password_version)
    "stroom.gchq.github.io/tls-revision"        = tostring(local.tls_revision)
  }
}

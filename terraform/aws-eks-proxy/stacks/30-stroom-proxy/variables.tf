variable "infra_state" {
  description = "Where the 10-infra stack's state is: the same bucket, key and region as in its backend config."
  type = object({
    bucket = string
    key    = string
    region = string
  })
}

variable "platform_state" {
  description = "Where the 20-platform stack's state is."
  type = object({
    bucket = string
    key    = string
    region = string
  })
}

# The inputs below are passed to modules/stroom-proxy, which validates them.
# See its variables.tf for the checks.

variable "admin_principal_arns" {
  description = "IAM principals allowed to change the data bucket's Object Lock settings and to disable or delete its KMS key, besides the identity running Terraform."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Tags added to every AWS resource."
  type        = map(string)
  default     = {}
}

variable "namespace" {
  description = "Kubernetes namespace for the proxies."
  type        = string
  default     = "stroom-proxy"
}

variable "chart_repository" {
  description = "Helm repository of the stroom-proxy chart. Ignored when chart_path is set."
  type        = string
  default     = "oci://ghcr.io/gchq/helm-charts"
}

variable "chart_version" {
  description = "Version of the stroom-proxy chart. Ignored when chart_path is set."
  type        = string
  default     = "0.1.0"
}

variable "chart_path" {
  description = "Local path to the stroom-proxy chart, for chart development (e.g. \"../../../../charts/stroom-proxy\")."
  type        = string
  default     = null
}

variable "proxy_deployments" {
  description = "Proxy deployments by colour. Normally one; two only during a blue/green upgrade. Each colour needs proxy nodes of the same colour in 10-infra."
  type = map(object({
    image_tag    = string
    image_digest = string
    replicas     = number
  }))
}

variable "active_colour" {
  description = "Colour that receives traffic from both ALB listeners."
  type        = string
}

variable "proxy_resources" {
  description = "Container resources of each proxy."
  type = object({
    requests = map(string)
    limits   = map(string)
  })
  default = {
    requests = { cpu = "1", memory = "4Gi" }
    limits   = { cpu = "2", memory = "4Gi" }
  }
}

variable "proxy_java_opts" {
  description = "JAVA_OPTS for the proxy. The default sizes the heap from the memory limit."
  type        = string
  default     = "-XX:InitialRAMPercentage=50 -XX:MaxRAMPercentage=60"
}

variable "proxy_data_volume_gb" {
  description = "Size of each proxy's data volume (GiB)."
  type        = number
  default     = 200
}

variable "proxy_id_prefix" {
  description = "Prefix of the proxy ID used in receipt IDs. null = the deployment name."
  type        = string
  default     = null
}

variable "load_balancer_scheme" {
  description = "\"internal\" (default) or \"internet-facing\" for the two NLBs. The ALB is always internal."
  type        = string
  default     = "internal"
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the NLBs on 443 directly (PrivateLink access is controlled by the endpoint services)."
  type        = list(string)
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the ALB's test listeners (:9443 mTLS, :9444 plain), which forward to the inactive colour during a blue/green upgrade. Empty = the listeners exist (they also make the inactive colour's health checks run) but nobody can reach them."
  type        = list(string)
  default     = []
}

variable "hostname" {
  description = "Host name of the non-mTLS endpoint (token and data feed key senders), e.g. proxy.example.internal."
  type        = string
}

variable "mtls_hostname" {
  description = "Host name of the mTLS endpoint (certificate senders), e.g. mtls.proxy.example.internal."
  type        = string
}

variable "route53_zone_id" {
  description = "Route 53 zone for the host names' alias records (and DNS validation with acm_public). null = manage DNS elsewhere."
  type        = string
  default     = null
}

variable "tls_certificate_source" {
  description = "Server certificate on the ALB: acm_private_ca (AWS Private CA), acm_public (DNS-validated in route53_zone_id), acm_existing (certificate_arn) or acm_imported (imported_certificate, e.g. a test CA's certificate in dev)."
  type        = string
  default     = "acm_private_ca"
}

variable "private_ca_arn" {
  description = "AWS Private CA for acm_private_ca."
  type        = string
  default     = null
}

variable "certificate_arn" {
  description = "ACM certificate covering both host names, for acm_existing."
  type        = string
  default     = null
}

variable "imported_certificate" {
  description = "PEM certificate (covering both host names), its private key and optional chain, imported into ACM for acm_imported. The key is kept in Terraform state: meant for dev and test certificates."
  type = object({
    certificate_pem       = string
    private_key_pem       = string
    certificate_chain_pem = optional(string)
  })
  default   = null
  sensitive = true
}

variable "alb_ssl_policy" {
  description = "TLS policy of the ALB listeners."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-Res-2021-06"
}

variable "alb_idle_timeout" {
  description = "ALB idle timeout (seconds), long enough for slow uploads."
  type        = number
  default     = 300
}

variable "deregistration_delay" {
  description = "Seconds the ALB keeps sending in-flight requests to a deregistering pod. The chart's preStop wait is based on it."
  type        = number
  default     = 120
}

variable "alb_access_logs_bucket" {
  description = "S3 bucket for ALB access logs (real client addresses, rejected requests). null = off."
  type        = string
  default     = null
}

variable "waf_web_acl_arn" {
  description = "AWS WAF web ACL to associate with the ALB. null = none."
  type        = string
  default     = null
}

variable "privatelink" {
  description = "VPC endpoint services on the two NLBs."
  type = object({
    enabled              = bool
    allowed_principals   = optional(list(string), [])
    acceptance_required  = optional(bool, true)
    verification_zone_id = optional(string)
  })
  default = { enabled = false }
}

variable "auth" {
  description = "Sender authentication. See section 6 of the design."
  type = object({
    required                 = optional(bool, true)
    types                    = optional(list(string), ["CERTIFICATE", "TOKEN", "DATA_FEED_KEY"])
    client_ca_bundle_pem     = optional(string)
    trust_store_pem_s3_key   = optional(string, "trust/client-ca.pem")
    client_crl_s3_keys       = optional(list(string), [])
    dfk_s3_prefix            = optional(string, "dfk/")
    data_feed_owner_meta_key = optional(string, "AccountId")
    openid = optional(object({
      issuer                        = string
      openid_configuration_endpoint = optional(string)
      allowed_audiences             = list(string)
      client_id                     = string
      client_secret_name            = optional(string)
      unique_identity_claim         = optional(string, "sub")
    }))
  })
  default = {}
}

variable "receipt_config_bucket" {
  description = "Existing bucket holding the DFK files and trust-store PEM. null = create one."
  type        = string
  default     = null
}

variable "dfk_sync_interval_seconds" {
  description = "How often each pod re-syncs the DFK files from S3."
  type        = number
  default     = 60
}

variable "downstream" {
  description = "Optional downstream Stroom (feed status, receipt policy, Stroom API keys)."
  type = object({
    scheme              = optional(string, "https")
    hostname            = string
    port                = optional(number, 443)
    path_prefix         = optional(string)
    api_key_secret_name = string
  })
  default = null
}

variable "receipt" {
  description = "Receipt check mode and fallback."
  type = object({
    check_mode      = optional(string, "RECEIVE_ALL")
    fallback_action = optional(string, "RECEIVE")
  })
  default = {}
}

variable "data_bucket_name" {
  description = "Existing data bucket (must have versioning and Object Lock in COMPLIANCE mode with a default retention; checked with the AWS CLI at plan time). null = create one."
  type        = string
  default     = null
}

variable "data_bucket_kms_key_arn" {
  description = "KMS key of an existing data bucket, if it uses SSE-KMS."
  type        = string
  default     = null
}

variable "data_retention_days" {
  description = "Object Lock COMPLIANCE retention (days) for new data objects. It can't be shortened for stored objects: choose per environment."
  type        = number
}

variable "data_expire_after_retention" {
  description = "Delete data objects once their retention has passed (lifecycle rule). false = keep them until removed by hand."
  type        = bool
  default     = false
}

variable "data_notifications" {
  description = "\"sqs\": announce new data objects on an SQS queue (for Stroom's S3/SQS ingest). \"none\": no notifications."
  type        = string
  default     = "sqs"
}

variable "forward_s3" {
  description = "S3 forwarding settings."
  type = object({
    key_template = optional(string, "$${type}/$${year}/$${month}/$${day}/$${feed}/$${uuid}.zip")
    multipart    = optional(bool, true)
  })
  default = {}
}

variable "aggregation" {
  description = "Proxy aggregation before forwarding."
  type = object({
    enabled               = optional(bool, true)
    frequency             = optional(string, "PT10M")
    max_items             = optional(number, 1000)
    max_uncompressed_size = optional(string, "1.0G")
  })
  default = {}
}

variable "extra_proxy_config" {
  description = "Extra proxyConfig settings, in the proxy's own keys, deep-merged over what this module renders."
  type        = any
  default     = {}
}

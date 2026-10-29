################################################################################
# From the 10-infra and 20-platform stacks
################################################################################

variable "name" {
  description = "Deployment name (10-infra). Prefixes AWS resource names."
  type        = string
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
}

variable "aws_region" {
  description = "AWS region."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the cluster."
  type        = string
}

variable "vpc_cidr" {
  description = "Primary CIDR of the VPC."
  type        = string
}

variable "lb_subnet_ids" {
  description = "Subnets for the ALB and the internal NLBs."
  type        = list(string)
}

variable "lb_subnet_cidrs" {
  description = "CIDRs of the lb subnets: the only sources proxy pods accept traffic from."
  type        = list(string)
}

variable "public_subnet_ids" {
  description = "Public subnets, for internet-facing NLBs."
  type        = list(string)
  default     = []
}

variable "node_security_group_id" {
  description = "Security group shared by the cluster's nodes (and so its pods)."
  type        = string
}

variable "proxy_node_colours" {
  description = "Proxy node colours from 10-infra: node_label and node_count per colour."
  type = map(object({
    node_label = object({ key = string, value = string })
    node_count = number
  }))
}

variable "secrets_name_prefix" {
  description = "Secrets Manager prefix the External Secrets Operator may read (20-platform)."
  type        = string
}

variable "storage_class_name" {
  description = "StorageClass for the proxy data volumes (20-platform)."
  type        = string
}

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

################################################################################
# Proxy deployments (blue/green colours)
################################################################################

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

  validation {
    condition     = length(var.proxy_deployments) >= 1 && length(var.proxy_deployments) <= 2
    error_message = "proxy_deployments must have one colour, or two during a blue/green upgrade."
  }

  validation {
    condition     = alltrue([for d in values(var.proxy_deployments) : can(regex("^sha256:[0-9a-f]{64}$", d.image_digest))])
    error_message = "Each deployment needs image_digest \"sha256:<64 hex>\": floating tags move (see scripts/latest-proxy-tag.sh)."
  }

  validation {
    condition     = alltrue([for d in values(var.proxy_deployments) : d.replicas >= 1])
    error_message = "replicas must be at least 1."
  }
}

variable "active_colour" {
  description = "Colour that receives traffic from both ALB listeners."
  type        = string

  validation {
    condition     = contains(keys(var.proxy_deployments), var.active_colour)
    error_message = "active_colour must be one of the colours in proxy_deployments."
  }
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

################################################################################
# Load balancers, TLS, DNS, PrivateLink
################################################################################

variable "load_balancer_scheme" {
  description = "\"internal\" (default) or \"internet-facing\" for the two NLBs. The ALB is always internal."
  type        = string
  default     = "internal"

  validation {
    condition     = contains(["internal", "internet-facing"], var.load_balancer_scheme)
    error_message = "load_balancer_scheme must be internal or internet-facing."
  }
}

variable "allowed_ingress_cidrs" {
  description = "CIDRs allowed to reach the NLBs on 443 directly (PrivateLink access is controlled by the endpoint services)."
  type        = list(string)

  validation {
    condition     = length(var.allowed_ingress_cidrs) > 0 && alltrue([for c in var.allowed_ingress_cidrs : can(cidrhost(c, 0))])
    error_message = "allowed_ingress_cidrs must be a non-empty list of IPv4 CIDRs."
  }
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach the ALB's test listeners (:9443 mTLS, :9444 plain), which forward to the inactive colour during a blue/green upgrade. Empty = the listeners exist (they also make the inactive colour's health checks run) but nobody can reach them."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for c in var.admin_cidrs : can(cidrhost(c, 0))])
    error_message = "admin_cidrs must contain IPv4 CIDRs."
  }
}

variable "hostname" {
  description = "Host name of the non-mTLS endpoint (token and data feed key senders), e.g. proxy.example.internal."
  type        = string
}

variable "mtls_hostname" {
  description = "Host name of the mTLS endpoint (certificate senders), e.g. mtls.proxy.example.internal."
  type        = string

  validation {
    condition     = var.mtls_hostname != var.hostname
    error_message = "mtls_hostname must differ from hostname: each has its own NLB and endpoint service."
  }
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

  validation {
    condition     = contains(["acm_private_ca", "acm_public", "acm_existing", "acm_imported"], var.tls_certificate_source)
    error_message = "tls_certificate_source must be acm_private_ca, acm_public, acm_existing or acm_imported."
  }
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

################################################################################
# Authentication and receipt
################################################################################

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

  validation {
    condition     = alltrue([for t in var.auth.types : contains(["CERTIFICATE", "CERTIFICATE_IDENTITY", "TOKEN", "DATA_FEED_KEY"], t)])
    error_message = "auth.types may contain CERTIFICATE, CERTIFICATE_IDENTITY, TOKEN and DATA_FEED_KEY."
  }

  validation {
    condition     = var.auth.dfk_s3_prefix == null || endswith(coalesce(var.auth.dfk_s3_prefix, "/"), "/")
    error_message = "auth.dfk_s3_prefix must end with \"/\"."
  }
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

  validation {
    condition     = contains(["FEED_STATUS", "RECEIPT_POLICY", "FEED_EXISTENCE", "RECEIVE_ALL", "DROP_ALL", "REJECT_ALL"], var.receipt.check_mode)
    error_message = "receipt.check_mode must be FEED_STATUS, RECEIPT_POLICY, FEED_EXISTENCE, RECEIVE_ALL, DROP_ALL or REJECT_ALL."
  }
}

################################################################################
# Data bucket (immutable) and forwarding
################################################################################

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

  validation {
    condition     = var.data_retention_days >= 1 && floor(var.data_retention_days) == var.data_retention_days
    error_message = "data_retention_days must be a whole number of days, at least 1."
  }
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

  validation {
    condition     = contains(["sqs", "none"], var.data_notifications)
    error_message = "data_notifications must be sqs or none."
  }
}

variable "forward_s3" {
  description = "S3 forwarding settings."
  type = object({
    key_template = optional(string, "$${type}/$${year}/$${month}/$${day}/$${feed}/$${uuid}.zip")
    multipart    = optional(bool, true)
  })
  default = {}

  validation {
    # The proxy's default template isn't unique per batch (F18).
    condition     = strcontains(lower(var.forward_s3.key_template), "$${uuid}") || strcontains(lower(var.forward_s3.key_template), "$${receiptid}")
    error_message = "forward_s3.key_template must contain $${uuid} or $${receiptId}, so every batch gets its own key."
  }
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

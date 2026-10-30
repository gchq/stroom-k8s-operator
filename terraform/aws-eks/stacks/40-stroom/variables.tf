variable "infra_state" {
  description = "Where the 10-infra stack's state is: the same bucket, key and region as in its backend config."
  type        = object({ bucket = string, key = string, region = string })
}

variable "platform_state" {
  description = "Where the 20-platform stack's state is."
  type        = object({ bucket = string, key = string, region = string })
}

variable "proxy_state" {
  description = "Where the 30-stroom-proxy stack's state is, when the proxy is in this cluster: Stroom ingests from its data bucket. null for a Stroom-only cluster, which takes the bucket from ingest (design 4.4)."
  type        = object({ bucket = string, key = string, region = string })
  default     = null
}

variable "tags" {
  description = "Extra tags added to every AWS resource."
  type        = map(string)
  default     = {}
}

# --- Stroom ---

variable "node_name_prefix" {
  description = "Prefix of the Stroom node names, e.g. stroom-dev gives stroom-dev-proc-0. Permanent."
  type        = string
}

variable "stroom_image" {
  description = "Stroom image: repository (default gchq/stroom), tag, and digest (recommended)."
  type = object({
    repository = optional(string, "gchq/stroom")
    tag        = string
    digest     = optional(string)
  })
}

variable "stopped" {
  description = "Stop every Stroom node, keeping the counts, for a version upgrade (design section 12)."
  type        = bool
  default     = false
}

variable "node_sets" {
  description = "Stroom node sets, matching 10-infra's stroom_node_sets. See modules/stroom/variables.tf."
  type = map(object({
    count          = number
    role           = string
    cpu            = number
    memory_gib     = number
    heap_gib       = number
    data_volume_gb = number
    nvme = optional(object({
      tmp_gib            = optional(number, 200)
      reference_data_gib = optional(number, 500)
      search_results_gib = optional(number, 200)
    }), {})
  }))
}

variable "extra_jvm_opts" {
  description = "Extra JVM options for every node, e.g. [\"-XX:+UseZGC\"]."
  type        = list(string)
  default     = []
}

variable "stream_volume" {
  description = "Shared stream volume: { type = \"efs\", throughput_mode = \"elastic\", backup = true }."
  type = object({
    type            = optional(string, "efs")
    throughput_mode = optional(string, "elastic")
    backup          = optional(bool, true)
  })
  default = {}
}

variable "database" {
  description = "The RDS for MySQL 8.4 instance. See modules/stroom-db/variables.tf."
  type = object({
    engine_version        = optional(string, "8.4")
    instance_class        = optional(string, "db.r6g.large")
    multi_az              = optional(bool, true)
    storage_gb            = optional(number, 200)
    max_storage_gb        = optional(number)
    backup_retention_days = optional(number, 14)
    deletion_protection   = optional(bool, true)
    max_connections       = optional(number, 1000)
    maintenance_window    = optional(string, "sun:03:00-sun:04:00")
    backup_window         = optional(string, "01:00-02:00")
    performance_insights  = optional(bool, true)
    apply_immediately     = optional(bool, false)

    app_user_password_version = optional(number, 1)
  })
  default = {}
}

variable "idp" {
  description = "The external identity provider (app registration made outside Terraform). See modules/stroom/variables.tf."
  type = object({
    type                      = optional(string, "entra")
    tenant_id                 = optional(string)
    discovery_url             = optional(string)
    client_id                 = string
    client_secret_name        = string
    client_secret_kms_key_arn = optional(string)
    first_admin = object({
      subject      = string
      display_name = string
    })
  })
}

variable "ingest" {
  description = <<-EOT
    The data bucket, for a Stroom-only cluster (proxy_state = null): bucket,
    queue_url, queue_arn, dlq_url, dlq_arn, kms_key_arn and expire_after_days
    (null = never). The bucket's owner must send its ObjectCreated events
    straight to the queue and grant Stroom's role read access (design 4.4).
    Ignored when proxy_state is set.
  EOT
  type = object({
    bucket            = optional(string)
    queue_url         = optional(string)
    queue_arn         = optional(string)
    dlq_url           = optional(string)
    dlq_arn           = optional(string)
    kms_key_arn       = optional(string)
    expire_after_days = optional(number)
  })
  default = {}
}

variable "raw_data_retention_days" {
  description = "The longest Stroom data retention rule for raw streams; must be less than the data bucket's expiry (design 7.3)."
  type        = number
}

variable "proxy_api_key_secret_name" {
  description = "Secrets Manager name, under 20-platform's secrets prefix, for the proxy's Stroom API key (design 8.1). Only with proxy_state; null = no key."
  type        = string
  default     = "stroom-proxy-api-key"
}

# --- access ---

variable "hostname" {
  description = "Host name of the Stroom UI and API."
  type        = string
}

variable "allowed_ingress_cidrs" {
  description = "Networks allowed to reach the ALB."
  type        = list(string)
}

variable "route53_zone_id" {
  description = "Route 53 zone for the host name's alias (and acm_public validation). null = DNS elsewhere."
  type        = string
  default     = null
}

variable "tls_certificate_source" {
  description = "acm_private_ca, acm_public, acm_existing or acm_imported (dev only)."
  type        = string
  default     = "acm_private_ca"
}

variable "private_ca_arn" {
  description = "AWS Private CA, for acm_private_ca."
  type        = string
  default     = null
}

variable "certificate_arn" {
  description = "ACM certificate, for acm_existing."
  type        = string
  default     = null
}

variable "imported_certificate_files" {
  description = "Paths to a PEM certificate, key and optional chain to import into ACM, for acm_imported (dev only: the key is kept in state)."
  type = object({
    certificate       = string
    private_key       = string
    certificate_chain = optional(string)
  })
  default = null
}

variable "alb_idle_timeout" {
  description = "ALB idle timeout in seconds."
  type        = number
  default     = 300
}

variable "alb_access_logs_bucket" {
  description = "S3 bucket for ALB access logs. null = off."
  type        = string
  default     = null
}

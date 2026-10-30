variable "infra_state" {
  description = "Where the 10-infra stack's state is: the same bucket, key and region as in its backend config."
  type = object({
    bucket = string
    key    = string
    region = string
  })
}

variable "tags" {
  description = "Extra tags added to every AWS resource."
  type        = map(string)
  default     = {}
}

# --- AWS Load Balancer Controller ---

variable "lb_controller_chart_version" {
  description = "Version of the aws-load-balancer-controller Helm chart. Its IAM policy is in modules/platform/lb-controller-iam-policy.json; update both together."
  type        = string
  default     = "3.6.2"
}

# --- gp3 StorageClass ---

variable "gp3_iops" {
  description = "Provisioned IOPS for gp3 volumes, including the proxy data volumes (3000-16000)."
  type        = number
  default     = 3000
}

variable "gp3_throughput" {
  description = "Throughput (MiB/s) for gp3 volumes (125-1000, at most gp3_iops / 4)."
  type        = number
  default     = 250
}

variable "ebs_kms_key_arn" {
  description = "KMS key for gp3 volumes. null = the account's default EBS key."
  type        = string
  default     = null
}

# --- CloudWatch ---

variable "cloudwatch_addon_version" {
  description = "Version of the amazon-cloudwatch-observability add-on. null = the cluster's default version when first created."
  type        = string
  default     = null
}

variable "log_retention_days" {
  description = "Retention of the Container Insights log groups (a CloudWatch Logs retention value)."
  type        = number
  default     = 90
}

variable "log_kms_key_arn" {
  description = "KMS key for the Container Insights log groups. null = CloudWatch Logs' default encryption."
  type        = string
  default     = null
}

# --- External Secrets Operator ---

variable "external_secrets_chart_version" {
  description = "Version of the external-secrets Helm chart."
  type        = string
  default     = "2.14.0"
}

variable "secrets_name_prefix" {
  description = "Secrets Manager name prefix the External Secrets Operator may read. null = \"stroom-proxy/<name>/\", where <name> is the 10-infra deployment name."
  type        = string
  default     = null
}

# --- Stroom (installed only when 10-infra has Stroom node sets) ---

variable "cert_manager_chart_version" {
  description = "Version of the cert-manager Helm chart."
  type        = string
  default     = "v1.21.3"
}

variable "trust_manager_chart_version" {
  description = "Version of the trust-manager Helm chart."
  type        = string
  default     = "v0.26.0"
}

variable "metrics_server_chart_version" {
  description = "Version of the metrics-server Helm chart."
  type        = string
  default     = "3.14.0"
}

variable "stroom_operator" {
  description = "Where the Stroom operator's charts and image come from. The defaults use this repository's charts and the gchq/stroom-k8s-operator image of the chart's appVersion. See modules/platform/variables.tf."
  type = object({
    chart_repository = optional(string)
    chart_version    = optional(string)
    image_repository = optional(string)
    image_tag        = optional(string)
  })
  default = {}
}

variable "cluster_name" {
  description = "Name of the EKS cluster."
  type        = string
}

variable "aws_region" {
  description = "AWS region of the cluster. Passed to controllers explicitly, because IMDS hop limit 1 stops pods reading it from instance metadata."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the cluster. Passed to the load balancer controller explicitly, for the same reason."
  type        = string
}

variable "system_node_label" {
  description = "Label (key and value) on the system nodes. Every component here is pinned to them."
  type        = object({ key = string, value = string })
}

# --- AWS Load Balancer Controller ---

variable "lb_controller_chart_version" {
  description = "Version of the aws-load-balancer-controller Helm chart (eks-charts). The IAM policy in lb-controller-iam-policy.json matches it; update both together. Helm doesn't upgrade the chart's CRDs, so apply the new release's CRDs before changing this."
  type        = string
  default     = "3.6.2"
}

# --- gp3 StorageClass ---

variable "gp3_iops" {
  description = "Default provisioned IOPS for gp3 volumes (3000-16000). A PVC's StorageClass can't be overridden per volume, so this is the proxy data volumes' IOPS."
  type        = number
  default     = 3000

  validation {
    condition     = var.gp3_iops >= 3000 && var.gp3_iops <= 16000
    error_message = "gp3_iops must be between 3000 and 16000."
  }
}

variable "gp3_throughput" {
  description = "Default throughput (MiB/s) for gp3 volumes (125-1000, and at most a quarter of gp3_iops)."
  type        = number
  default     = 250

  validation {
    condition     = var.gp3_throughput >= 125 && var.gp3_throughput <= 1000 && var.gp3_throughput <= var.gp3_iops / 4
    error_message = "gp3_throughput must be between 125 and 1000 MiB/s, and at most gp3_iops / 4."
  }
}

variable "ebs_kms_key_arn" {
  description = "KMS key for encrypting gp3 volumes. null = the account's default EBS key (aws/ebs)."
  type        = string
  default     = null
}

# --- CloudWatch ---

variable "cloudwatch_addon_version" {
  description = "Version of the amazon-cloudwatch-observability EKS add-on, e.g. \"v4.1.0-eksbuild.1\". null = the default version for the cluster when first created; set it to upgrade. Must be 1.7.0 or later, the first version whose pods tolerate the proxy nodes' taint."
  type        = string
  default     = null

  validation {
    condition = var.cloudwatch_addon_version == null ? true : (
      can(regex("^v([0-9]+)\\.([0-9]+)\\.", var.cloudwatch_addon_version)) ? (
        tonumber(regex("^v([0-9]+)\\.([0-9]+)\\.", var.cloudwatch_addon_version)[0]) > 1 || (
          tonumber(regex("^v([0-9]+)\\.([0-9]+)\\.", var.cloudwatch_addon_version)[0]) == 1 &&
          tonumber(regex("^v([0-9]+)\\.([0-9]+)\\.", var.cloudwatch_addon_version)[1]) >= 7
        )
      ) : false
    )
    error_message = "cloudwatch_addon_version must look like \"v4.1.0-eksbuild.1\" and be v1.7.0 or later (earlier versions don't run Fluent Bit on tainted proxy nodes)."
  }
}

variable "log_retention_days" {
  description = "Retention of the Container Insights log groups (application, dataplane, host, performance)."
  type        = number
  default     = 90

  validation {
    condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.log_retention_days)
    error_message = "log_retention_days must be a CloudWatch Logs retention value: 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288 or 3653."
  }
}

variable "log_kms_key_arn" {
  description = "KMS key for encrypting the Container Insights log groups. null = CloudWatch Logs' default encryption."
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
  description = "Secrets Manager name prefix the External Secrets Operator may read, e.g. \"stroom-proxy/prod/\". Must end with \"/\"."
  type        = string

  validation {
    condition     = endswith(var.secrets_name_prefix, "/") && length(var.secrets_name_prefix) > 1
    error_message = "secrets_name_prefix must end with \"/\", e.g. \"stroom-proxy/prod/\"."
  }
}

variable "tags" {
  description = "Tags added to every AWS resource."
  type        = map(string)
  default     = {}
}

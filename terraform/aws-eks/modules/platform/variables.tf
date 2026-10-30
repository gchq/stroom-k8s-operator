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

variable "lb_controller_iam_policy" {
  description = <<-EOT
    IAM policy of the AWS Load Balancer Controller.
    "full"                 : the upstream policy for the chart version
                             (lb-controller-iam-policy.json). It can also change
                             security group rules and any ALB's listeners and
                             rules, which TargetGroupBinding doesn't need.
    "target_group_binding" : describes, plus registering and deregistering targets
                             in existing target groups (lb-controller-tgb-iam-policy.json).
                             Enough for TargetGroupBinding without spec.networking,
                             as far as the controller's code shows, but not yet
                             proven on a cluster: switch, roll a proxy pod and
                             check its readiness gate and the controller's logs
                             for AccessDenied before relying on it.
  EOT
  type        = string
  default     = "full"

  validation {
    condition     = contains(["full", "target_group_binding"], var.lb_controller_iam_policy)
    error_message = "lb_controller_iam_policy must be \"full\" or \"target_group_binding\"."
  }
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
  description = "Secrets Manager name prefix for the deployment's secrets, e.g. \"stroom-proxy/prod/\". Must end with \"/\". Passed on to the workload stacks, whose own roles read their secrets under it; the External Secrets controller's role only assumes those roles."
  type        = string

  validation {
    condition     = endswith(var.secrets_name_prefix, "/") && length(var.secrets_name_prefix) > 1
    error_message = "secrets_name_prefix must end with \"/\", e.g. \"stroom-proxy/prod/\"."
  }
}

# --- Stroom (only with Stroom node sets) ---

variable "stroom_enabled" {
  description = "Install what Stroom needs: cert-manager, trust-manager and the in-cluster CA, metrics-server, and the Stroom operator. True when the cluster has Stroom node sets."
  type        = bool
  default     = false
}

variable "cert_manager_chart_version" {
  description = "Version of the cert-manager Helm chart (jetstack)."
  type        = string
  default     = "v1.21.3"
}

variable "trust_manager_chart_version" {
  description = "Version of the trust-manager Helm chart (jetstack)."
  type        = string
  default     = "v0.26.0"
}

variable "metrics_server_chart_version" {
  description = "Version of the metrics-server Helm chart."
  type        = string
  default     = "3.14.0"
}

variable "internal_ca_name" {
  description = "Name of the in-cluster CA: its ClusterIssuer, and the ConfigMap holding its certificate (key ca.crt) in each labelled namespace."
  type        = string
  default     = "stroom-internal-ca"
}

variable "internal_ca_namespace_label" {
  description = "Label that makes trust-manager publish the CA certificate into a namespace."
  type        = object({ key = string, value = string })
  default     = { key = "stroom.gchq.github.io/internal-ca", value = "true" }
}

variable "internal_ca_additional_trusted_certificates" {
  description = "PEM CA certificates published in the in-cluster CA's trust bundle alongside its current certificate. Empty normally; during a root rotation, the old CA certificate, so certificates it signed stay trusted until they are reissued."
  type        = string
  default     = ""
  nullable    = false

  validation {
    condition     = var.internal_ca_additional_trusted_certificates == "" || strcontains(var.internal_ca_additional_trusted_certificates, "-----BEGIN CERTIFICATE-----")
    error_message = "internal_ca_additional_trusted_certificates must be empty or PEM certificates (-----BEGIN CERTIFICATE-----)."
  }
}

variable "stroom_operator" {
  description = <<-EOT
    Where the Stroom operator comes from.

    chart_repository : Helm repository of the stroom-operator and
                       stroom-operator-crds charts, e.g.
                       "oci://ghcr.io/gchq/helm-charts". null = this
                       repository's charts directory, which has changes not
                       yet released (node name prefix, directories, database
                       TLS, API keys with an external IdP).
    chart_version    : chart version; null = the latest (repository) or the
                       local chart.
    image_repository : full image repository, e.g. an ECR repository holding a
                       build of this branch. null = gchq/stroom-k8s-operator.
                       Required with the local charts.
    image_tag        : image tag. null = the chart's appVersion. Required with
                       the local charts.

    The local charts' CRDs are newer than the released image their appVersion
    names (gchq/stroom-k8s-operator:2.0.0), which ignores nodeNamePrefix and
    the other new fields and would name Stroom nodes permanently wrong, so with
    the local charts give the image of a matching build.
  EOT
  type = object({
    chart_repository = optional(string)
    chart_version    = optional(string)
    image_repository = optional(string)
    image_tag        = optional(string)
  })
  default  = {}
  nullable = false

  validation {
    condition = (
      !var.stroom_enabled ||
      var.stroom_operator.chart_repository != null ||
      (var.stroom_operator.image_repository != null && var.stroom_operator.image_tag != null)
    )
    error_message = "With the operator charts from this repository (stroom_operator.chart_repository null), set stroom_operator.image_repository and image_tag to an operator image built from the same commit. The charts' default image (gchq/stroom-k8s-operator:2.0.0) is older than their CRDs and ignores nodeNamePrefix, so Stroom's node names would be wrong for good."
  }
}

variable "tags" {
  description = "Tags added to every AWS resource."
  type        = map(string)
  default     = {}
}

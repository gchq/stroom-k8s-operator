variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
}

variable "name" {
  description = "Name of the deployment. Used as the EKS cluster name and as a prefix for other resources."
  type        = string

  validation {
    # IAM role name prefixes such as "<name>-cluster-" are limited to 38 characters.
    condition     = can(regex("^[a-z][a-z0-9-]{1,27}[a-z0-9]$", var.name))
    error_message = "name must be 3-29 characters of lower-case letters, digits and hyphens, starting with a letter and not ending with a hyphen."
  }
}

variable "tags" {
  description = "Extra tags added to every resource."
  type        = map(string)
  default     = {}
}

# --- network ---

variable "vpc_cidr" {
  description = "CIDR block for a new VPC (/16 to /20). Ignored when existing_vpc_id is set."
  type        = string
  default     = "10.40.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones for a new VPC (2-4). Ignored when azs is set."
  type        = number
  default     = 3
}

variable "azs" {
  description = "Availability zone names (e.g. [\"eu-west-2a\", \"eu-west-2b\", \"eu-west-2c\"]) or zone IDs (e.g. [\"euw2-az2\", ...]) for a new VPC, in order. null = the first az_count zones that are available at plan time, which can shift if a zone is impaired. Set it to the availability_zones output (names, not IDs, for an existing cluster: IDs would replace the subnets). Never reorder or remove entries: the node groups are keyed by position."
  type        = list(string)
  default     = null
}

variable "nat_gateway_mode" {
  description = "\"single\" (cheaper) or \"one_per_az\" (survives an AZ outage)."
  type        = string
  default     = "one_per_az"
}

variable "enable_vpc_endpoints" {
  description = "Create VPC endpoints for S3, ECR, STS and CloudWatch Logs in a new VPC."
  type        = bool
  default     = false
}

variable "existing_vpc_id" {
  description = "Use an existing VPC instead of creating one."
  type        = string
  default     = null
}

variable "existing_private_subnet_ids" {
  description = "Private subnets in existing_vpc_id, one per AZ."
  type        = list(string)
  default     = []
}

variable "existing_public_subnet_ids" {
  description = "Public subnets in existing_vpc_id, for internet-facing NLBs."
  type        = list(string)
  default     = []
}

variable "existing_lb_subnet_ids" {
  description = "Subnets in existing_vpc_id, one per AZ, used only by the ALB and the internal NLBs (at least /27 each)."
  type        = list(string)
  default     = []
}

# --- cluster ---

variable "cluster_version" {
  description = "Kubernetes minor version for EKS. Upgrade one minor version at a time."
  type        = string
  default     = "1.37"
}

variable "admin_principal_arns" {
  description = "IAM principal ARNs given cluster-admin, in addition to the identity running Terraform."
  type        = list(string)
  default     = []
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint. Empty = private endpoint only."
  type        = list(string)
  default     = []
}

variable "cluster_log_types" {
  description = "Control plane log types sent to CloudWatch Logs. Empty turns control plane logging off."
  type        = list(string)
  default     = []
}

variable "cluster_log_retention_days" {
  description = "Retention for the control plane log group."
  type        = number
  default     = 90
}

# --- system node group ---

variable "system_node_instance_type" {
  description = "Instance type for the system node group (cluster services)."
  type        = string
  default     = "t3.medium"
}

variable "system_node_count" {
  description = "Number of system nodes. With stroom_node_sets, system_node_count × (pods per node − 7) must be at least 32, e.g. 2 × t3.large or m6i.large; the default 2 × t3.medium is for a proxy-only cluster."
  type        = number
  default     = 2
}

# --- proxy node groups ---

variable "proxy_node_colours" {
  description = <<-EOT
    Proxy node groups by colour. Each colour gets one node group per AZ. Add a
    second colour only for a blue/green upgrade, and remove the old one once its
    proxies have drained. See modules/eks/variables.tf for the fields.
  EOT
  type = map(object({
    instance_types      = list(string)
    capacity_type       = optional(string, "ON_DEMAND")
    nodes_per_az        = optional(number, 1)
    kubernetes_version  = string
    ami_release_version = optional(string)
    root_volume_gb      = optional(number, 50)
  }))
  default = {
    blue = {
      instance_types     = ["m6i.xlarge"]
      kubernetes_version = "1.37"
    }
  }

  validation {
    condition     = length(var.proxy_node_colours) > 0 || length(var.stroom_node_sets) > 0
    error_message = "Set proxy_node_colours, stroom_node_sets or both: a cluster with neither runs nothing."
  }
}

# --- Stroom node groups ---

variable "stroom_node_sets" {
  description = <<-EOT
    Stroom node groups by Stroom node set (e.g. proc, ui), for the 40-stroom
    stack. Empty (the default) for a cluster with only Stroom-Proxy. The keys
    must match the node set names in 40-stroom, and node_count its counts. Use
    az_overrides to change one AZ group's AMI, Kubernetes version or instance
    types at a time. With Stroom, the system nodes need at least 2 × t3.large
    (see system_node_count). See modules/eks/variables.tf for the fields.
  EOT
  type = map(object({
    instance_types      = list(string)
    node_count          = number
    kubernetes_version  = string
    ami_release_version = optional(string)
    root_volume_gb      = optional(number, 50)
    az_overrides = optional(map(object({
      instance_types      = optional(list(string))
      kubernetes_version  = optional(string)
      ami_release_version = optional(string)
    })), {})
  }))
  default = {}
}

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
  description = "Number of availability zones for a new VPC (2-4)."
  type        = number
  default     = 3
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
  description = "Number of system nodes."
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
}

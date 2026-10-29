variable "name" {
  description = "Name prefix for the VPC and its resources. Also used as the EKS cluster name in subnet tags."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for a new VPC. Must be /16 to /20. Private subnets take the first half of the range; public and lb subnets take small blocks three quarters in."
  type        = string
  default     = "10.40.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(split("/", var.vpc_cidr)[1]) >= 16 && tonumber(split("/", var.vpc_cidr)[1]) <= 20
    error_message = "vpc_cidr must be a valid IPv4 CIDR between /16 and /20."
  }
}

variable "az_count" {
  description = "Number of availability zones to use for a new VPC."
  type        = number
  default     = 3

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 4
    error_message = "az_count must be between 2 and 4."
  }
}

variable "nat_gateway_mode" {
  description = "NAT gateways for a new VPC: \"single\" (one shared, cheaper) or \"one_per_az\" (survives an AZ outage)."
  type        = string
  default     = "one_per_az"

  validation {
    condition     = contains(["single", "one_per_az"], var.nat_gateway_mode)
    error_message = "nat_gateway_mode must be \"single\" or \"one_per_az\"."
  }
}

variable "enable_vpc_endpoints" {
  description = "Create VPC endpoints for S3 (gateway), ECR, STS and CloudWatch Logs in a new VPC, so that traffic to those services avoids the NAT gateways."
  type        = bool
  default     = false
}

variable "existing_vpc_id" {
  description = "Use this VPC instead of creating one. Set existing_private_subnet_ids and existing_lb_subnet_ids too, and existing_public_subnet_ids for internet-facing NLBs."
  type        = string
  default     = null
}

variable "existing_private_subnet_ids" {
  description = "Private subnets in existing_vpc_id, one per AZ, for nodes and pods. They need a route to a NAT gateway (or VPC endpoints) for image pulls and AWS APIs."
  type        = list(string)
  default     = []

  validation {
    condition     = var.existing_vpc_id == null || length(var.existing_private_subnet_ids) >= 2
    error_message = "existing_private_subnet_ids needs at least two subnets (in different AZs) when existing_vpc_id is set."
  }
}

variable "existing_public_subnet_ids" {
  description = "Public subnets in existing_vpc_id, for internet-facing NLBs. May be empty for internal-only deployments."
  type        = list(string)
  default     = []
}

variable "existing_lb_subnet_ids" {
  description = "Subnets in existing_vpc_id, one per AZ, used only by the ALB and the NLBs. Proxy pods accept traffic only from these subnets' ranges, so nothing else should run in them. Each must be at least a /27."
  type        = list(string)
  default     = []

  validation {
    condition     = var.existing_vpc_id == null || length(var.existing_lb_subnet_ids) >= 2
    error_message = "existing_lb_subnet_ids needs at least two subnets (in different AZs) when existing_vpc_id is set."
  }
}

variable "tags" {
  description = "Tags added to every resource."
  type        = map(string)
  default     = {}
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as a prefix for IAM roles and node groups."
  type        = string
}

variable "kubernetes_version" {
  description = "Kubernetes minor version of the control plane and system nodes, e.g. \"1.37\". Upgrade one minor version at a time."
  type        = string

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must look like \"1.37\"."
  }
}

variable "vpc_id" {
  description = "VPC to create the cluster in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets (one per AZ) for the control plane network interfaces and the nodes. Each proxy colour gets one node group per subnet."
  type        = list(string)
}

variable "admin_principal_arns" {
  description = "IAM role or user ARNs given cluster-admin through EKS access entries, in addition to the identity that creates the cluster. Don't list that identity here too: EKS rejects a second access entry for it."
  type        = list(string)
  default     = []

  validation {
    condition     = length(distinct(var.admin_principal_arns)) == length(var.admin_principal_arns)
    error_message = "admin_principal_arns contains duplicates."
  }
}

variable "api_allowed_cidrs" {
  description = "CIDRs allowed to reach the public Kubernetes API endpoint. Empty means the public endpoint is turned off and the API is reachable only from inside the VPC."
  type        = list(string)
  default     = []

  validation {
    condition     = !contains(var.api_allowed_cidrs, "0.0.0.0/0")
    error_message = "api_allowed_cidrs must not contain 0.0.0.0/0. List the networks that need the API, or leave it empty for a private-only endpoint."
  }
}

variable "cluster_log_types" {
  description = "Control plane log types sent to CloudWatch Logs (any of api, audit, authenticator, controllerManager, scheduler). Empty turns control plane logging off."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for t in var.cluster_log_types : contains(["api", "audit", "authenticator", "controllerManager", "scheduler"], t)])
    error_message = "cluster_log_types may only contain api, audit, authenticator, controllerManager and scheduler."
  }
}

variable "cluster_log_retention_days" {
  description = "Retention for the control plane log group, when cluster_log_types is not empty."
  type        = number
  default     = 90
}

# --- system node group: cluster services (CoreDNS, controllers, operators) ---

variable "system_node_instance_type" {
  description = "Instance type for the system node group."
  type        = string
  default     = "t3.medium"
}

variable "system_node_count" {
  description = "Number of system nodes, spread across AZs."
  type        = number
  default     = 2

  validation {
    condition     = var.system_node_count >= 1
    error_message = "system_node_count must be at least 1."
  }
}

# --- proxy node groups: Stroom-Proxy pods only (tainted), one set per colour ---

variable "proxy_node_colours" {
  description = <<-EOT
    Proxy node groups, keyed by colour (e.g. "blue", "green"). Each colour gets
    one managed node group per AZ, labelled stroom-proxy/colour=<colour>. A
    second colour exists only during a blue/green upgrade.

    instance_types      : x86_64 types only (the gchq/stroom-proxy image is amd64-only).
    capacity_type       : ON_DEMAND (recommended) or SPOT.
    nodes_per_az        : fixed node count in each AZ.
    kubernetes_version  : kubelet minor version, e.g. "1.37". Explicit, so a control
                          plane upgrade doesn't roll proxy nodes in place.
    ami_release_version : EKS AMI release, e.g. "1.37.4-20261020". null = the latest
                          release when the colour is created, then left unchanged.
    root_volume_gb      : root volume size; proxy data is on separate EBS volumes.
  EOT
  type = map(object({
    instance_types      = list(string)
    capacity_type       = optional(string, "ON_DEMAND")
    nodes_per_az        = optional(number, 1)
    kubernetes_version  = string
    ami_release_version = optional(string)
    root_volume_gb      = optional(number, 50)
  }))

  validation {
    condition     = length(var.proxy_node_colours) >= 1 && length(var.proxy_node_colours) <= 2
    error_message = "proxy_node_colours must have one colour, or two during a blue/green upgrade."
  }

  validation {
    condition     = alltrue([for c in keys(var.proxy_node_colours) : can(regex("^[a-z][a-z0-9]{0,9}$", c))])
    error_message = "proxy_node_colours keys must be 1-10 lower-case letters or digits, starting with a letter (e.g. blue, green)."
  }

  validation {
    condition     = alltrue([for c in values(var.proxy_node_colours) : length(c.instance_types) > 0])
    error_message = "Each proxy node colour needs at least one instance type."
  }

  validation {
    # Graviton families have a "g" after the generation number (m7g, c7gn,
    # r8gd, t4g, hpc7g, ...). a1 is the first-generation Graviton.
    condition = alltrue(flatten([
      for c in values(var.proxy_node_colours) : [
        for t in c.instance_types : !can(regex("^(a1|[a-z]+[0-9]+[a-z]*g[a-z]*)\\.", lower(t)))
      ]
    ]))
    error_message = "proxy_node_colours contains a Graviton (arm64) instance type. The gchq/stroom-proxy image is published for amd64 only, so use an x86_64 type such as m6i, m7i or c7i."
  }

  validation {
    condition     = alltrue([for c in values(var.proxy_node_colours) : contains(["ON_DEMAND", "SPOT"], c.capacity_type)])
    error_message = "capacity_type must be ON_DEMAND or SPOT."
  }

  validation {
    condition     = alltrue([for c in values(var.proxy_node_colours) : c.nodes_per_az >= 1])
    error_message = "nodes_per_az must be at least 1, so every AZ that holds a proxy volume has a node."
  }

  validation {
    condition     = alltrue([for c in values(var.proxy_node_colours) : c.root_volume_gb >= 20])
    error_message = "root_volume_gb must be at least 20."
  }

  validation {
    # Kubelets may be up to three minor versions older than the control plane, never newer.
    condition = alltrue([
      for c in values(var.proxy_node_colours) :
      can(regex("^1\\.[0-9]+$", c.kubernetes_version)) ? (
        tonumber(split(".", var.kubernetes_version)[1]) - tonumber(split(".", c.kubernetes_version)[1]) >= 0 &&
        tonumber(split(".", var.kubernetes_version)[1]) - tonumber(split(".", c.kubernetes_version)[1]) <= 3
      ) : false
    ])
    error_message = "Each colour's kubernetes_version must look like \"1.37\" and be the cluster's version or up to three minor versions older."
  }

  validation {
    condition = alltrue([
      for c in values(var.proxy_node_colours) :
      c.ami_release_version == null ? true : startswith(c.ami_release_version, "${c.kubernetes_version}.")
    ])
    error_message = "ami_release_version must belong to the colour's kubernetes_version (e.g. \"1.37.4-20261020\" for 1.37)."
  }
}

variable "tags" {
  description = "Tags added to every resource."
  type        = map(string)
  default     = {}
}

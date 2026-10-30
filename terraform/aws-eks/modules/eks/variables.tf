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
    condition     = alltrue([for c in var.api_allowed_cidrs : can(cidrhost(c, 0))])
    error_message = "api_allowed_cidrs must contain IPv4 CIDRs, e.g. \"203.0.113.10/32\"."
  }

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
  description = "Number of system nodes, spread across AZs. With Stroom node sets the system nodes also run cert-manager, trust-manager, metrics-server, the EFS CSI controller and the Stroom operator: about 24 cluster service pods plus 7 DaemonSet pods per node, so 2 × t3.medium (17 pods each) is too small; use at least 2 × t3.large or m6i.large."
  type        = number
  default     = 2

  validation {
    condition     = var.system_node_count >= 1
    error_message = "system_node_count must be at least 1."
  }

  validation {
    # Pods the system nodes can hold beyond their DaemonSets, for types whose
    # limit is known; other types are only warned about (check.system_node_capacity).
    condition = (
      length(var.stroom_node_sets) == 0 ||
      lookup(local.max_pods_by_instance_type, var.system_node_instance_type, null) == null ||
      var.system_node_count * (lookup(local.max_pods_by_instance_type, var.system_node_instance_type, 0) - local.system_daemonset_pods) >= local.stroom_system_pods
    )
    error_message = "With Stroom node sets, ${var.system_node_count} × ${var.system_node_instance_type} system nodes don't have enough pod slots: beyond ${local.system_daemonset_pods} DaemonSet pods per node they need ${local.stroom_system_pods} slots (about 24 cluster service pods plus headroom for rolling updates), i.e. system_node_count × (max pods − ${local.system_daemonset_pods}) ≥ ${local.stroom_system_pods}. Use at least 2 × t3.large or 2 × m6i.large (or 3 for one per AZ)."
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
    condition     = length(var.proxy_node_colours) <= 2
    error_message = "proxy_node_colours must have one colour, two during a blue/green upgrade, or none for a cluster without Stroom-Proxy."
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

# --- Stroom node groups: Stroom pods only (tainted), one set per Stroom node set ---

variable "stroom_node_sets" {
  description = <<-EOT
    Stroom node groups, keyed by the Stroom node set they run (e.g. "proc", "ui").
    Each set's nodes are spread over the AZs, one managed node group per AZ that
    has any (stroom-<set>-az<n>), so a pod always has a node in its EBS volume's
    AZ. Nodes are labelled stroom/node-set=<set> and tainted workload=stroom.
    Empty for a cluster without Stroom.

    instance_types      : x86_64 types with instance-store NVMe (r6id, m6id, c6id,
                          i4i, ...): the NVMe disks become a RAID0 array for
                          kubelet and containerd, which holds Stroom's emptyDir
                          directories (reference data, search results, temp).
    node_count          : nodes in the set, spread over the AZs in order (2 nodes in
                          3 AZs: az1 and az2). Stroom nodes own their index shards,
                          so only raise it, together with the node set's count.
    kubernetes_version  : kubelet minor version, e.g. "1.37". Explicit, so a control
                          plane upgrade doesn't roll Stroom nodes.
    ami_release_version : EKS AMI release. null = the latest when the node group is
                          created, then left unchanged.
    root_volume_gb      : root volume size. Container images and emptyDirs are on NVMe.
    az_overrides        : per AZ group ("az1", "az2", ...), instance_types,
                          kubernetes_version and/or ami_release_version that
                          replace the set's for that group only. The AZ groups are
                          separate node groups that Terraform updates in parallel,
                          so changing the set's AMI, version or instance types
                          drains (or, for instance types, replaces) every AZ's
                          nodes at once, more than the PDB allows. Change one AZ
                          group at a time here, then move the set's own value and
                          remove the overrides (a no-op).

    The node groups are keyed by subnet index, so the private subnets' number and
    order must not change once Stroom nodes exist: the plan fails if a group would
    move to another subnet, shrink or disappear.
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

  validation {
    # Only AZ groups the set has: node_count nodes over the subnets fill az1, az2, ... in order.
    condition = alltrue(flatten([
      for s in values(var.stroom_node_sets) : [
        for az in keys(s.az_overrides) :
        can(regex("^az[1-9][0-9]*$", az)) ? tonumber(trimprefix(az, "az")) <= min(s.node_count, length(var.private_subnet_ids)) : false
      ]
    ]))
    error_message = "az_overrides keys must name one of the node set's AZ groups: \"az1\" up to \"az<n>\", where n is the smaller of node_count and the number of private subnets."
  }

  validation {
    condition = alltrue(flatten([
      for s in values(var.stroom_node_sets) : [
        for o in values(s.az_overrides) : o.instance_types == null ? true : length(o.instance_types) > 0
      ]
    ]))
    error_message = "An az_overrides entry's instance_types must not be empty (leave it out to keep the set's)."
  }

  validation {
    condition     = alltrue([for s in keys(var.stroom_node_sets) : can(regex("^[a-z][a-z0-9]{0,9}$", s))])
    error_message = "stroom_node_sets keys must be 1-10 lower-case letters or digits, starting with a letter (e.g. proc, ui), as the Stroom node set names."
  }

  validation {
    condition     = alltrue([for s in values(var.stroom_node_sets) : length(s.instance_types) > 0])
    error_message = "Each Stroom node set needs at least one instance type."
  }

  validation {
    # As for the proxy: no Graviton until the gchq/stroom image is published for arm64.
    condition = alltrue(flatten([
      for s in values(var.stroom_node_sets) : [
        for t in concat(s.instance_types, flatten([for o in values(s.az_overrides) : coalesce(o.instance_types, [])])) :
        !can(regex("^(a1|[a-z]+[0-9]+[a-z]*g[a-z]*)\\.", lower(t)))
      ]
    ]))
    error_message = "stroom_node_sets contains a Graviton (arm64) instance type. Use an x86_64 type with instance-store NVMe, such as r6id, m6id or i4i."
  }

  validation {
    # Instance-store families have a "d" after the generation number (r6id, m5dn,
    # x2idn), or are storage-optimised (i3, i3en, i4i, im4gn is Graviton).
    condition = alltrue(flatten([
      for s in values(var.stroom_node_sets) : [
        for t in concat(s.instance_types, flatten([for o in values(s.az_overrides) : coalesce(o.instance_types, [])])) :
        can(regex("^([a-z]+[0-9]+[a-z]*d[a-z]*|i[0-9]+[a-z]*)\\.", lower(t)))
      ]
    ]))
    error_message = "Stroom node instance types need instance-store NVMe (a \"d\" family such as r6id, m6id or c6id, or i4i), which holds Stroom's reference data, search results and temp files."
  }

  validation {
    condition     = alltrue([for s in values(var.stroom_node_sets) : s.node_count >= 1 && floor(s.node_count) == s.node_count])
    error_message = "node_count must be a whole number, at least 1."
  }

  validation {
    condition     = alltrue([for s in values(var.stroom_node_sets) : s.root_volume_gb >= 20])
    error_message = "root_volume_gb must be at least 20."
  }

  validation {
    condition = alltrue(flatten([
      for s in values(var.stroom_node_sets) : [
        for v in concat([s.kubernetes_version], [for o in values(s.az_overrides) : o.kubernetes_version if o.kubernetes_version != null]) :
        can(regex("^1\\.[0-9]+$", v)) ? (
          tonumber(split(".", var.kubernetes_version)[1]) - tonumber(split(".", v)[1]) >= 0 &&
          tonumber(split(".", var.kubernetes_version)[1]) - tonumber(split(".", v)[1]) <= 3
        ) : false
      ]
    ]))
    error_message = "Each Stroom node set's kubernetes_version (and any in its az_overrides) must look like \"1.37\" and be the cluster's version or up to three minor versions older."
  }

  validation {
    condition = alltrue([
      for s in values(var.stroom_node_sets) :
      s.ami_release_version == null ? true : startswith(s.ami_release_version, "${s.kubernetes_version}.")
    ])
    error_message = "ami_release_version must belong to the node set's kubernetes_version (e.g. \"1.37.4-20261020\" for 1.37)."
  }

  validation {
    # An AZ group's AMI must match its own Kubernetes version: the override's,
    # or the set's when the override doesn't change it.
    condition = alltrue(flatten([
      for s in values(var.stroom_node_sets) : [
        for o in values(s.az_overrides) :
        o.ami_release_version == null && o.kubernetes_version == null ? true : startswith(
          coalesce(o.ami_release_version, s.ami_release_version, "${coalesce(o.kubernetes_version, s.kubernetes_version)}."),
          "${coalesce(o.kubernetes_version, s.kubernetes_version)}."
        )
      ]
    ]))
    error_message = "Each az_overrides entry's AMI must belong to that AZ group's Kubernetes version. When an override changes kubernetes_version, give it a matching ami_release_version too (or leave the set's ami_release_version null)."
  }
}

variable "tags" {
  description = "Tags added to every resource."
  type        = map(string)
  default     = {}
}

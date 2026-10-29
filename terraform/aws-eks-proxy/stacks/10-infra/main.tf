locals {
  tags = merge(
    {
      Project   = "stroom-proxy"
      Stack     = "10-infra"
      Cluster   = var.name
      ManagedBy = "terraform"
    },
    var.tags,
  )
}

module "network" {
  source = "../../modules/network"

  name                        = var.name
  vpc_cidr                    = var.vpc_cidr
  az_count                    = var.az_count
  nat_gateway_mode            = var.nat_gateway_mode
  enable_vpc_endpoints        = var.enable_vpc_endpoints
  existing_vpc_id             = var.existing_vpc_id
  existing_private_subnet_ids = var.existing_private_subnet_ids
  existing_public_subnet_ids  = var.existing_public_subnet_ids
  existing_lb_subnet_ids      = var.existing_lb_subnet_ids
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = var.name
  kubernetes_version = var.cluster_version

  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  admin_principal_arns       = var.admin_principal_arns
  api_allowed_cidrs          = var.api_allowed_cidrs
  cluster_log_types          = var.cluster_log_types
  cluster_log_retention_days = var.cluster_log_retention_days

  system_node_instance_type = var.system_node_instance_type
  system_node_count         = var.system_node_count

  proxy_node_colours = var.proxy_node_colours
}

check "proxy_nodes_on_demand" {
  assert {
    condition     = alltrue([for c in values(var.proxy_node_colours) : c.capacity_type == "ON_DEMAND"])
    error_message = "Some proxy nodes use SPOT capacity. A Spot interruption gives two minutes' notice, less than a proxy pod takes to drain, and stops a proxy that may hold unsent data. The data is kept and sent once the pod is rescheduled, but that pod's receipt and forwarding stop until then."
  }
}

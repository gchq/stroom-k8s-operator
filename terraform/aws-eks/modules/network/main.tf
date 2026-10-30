locals {
  create_vpc = var.existing_vpc_id == null

  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # Private subnets (nodes, pods): one /19 per AZ in a /16, in the first half
  # of the range. Public subnets (NAT gateways, internet-facing NLBs): one /22
  # per AZ in a /16, starting three quarters in. Smaller VPCs scale the same way.
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 3, i)]
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 6, 48 + i)]

  # LB subnets (the ALB and internal NLBs only): always /26, which leaves an
  # ALB room to scale, carved from the block after the public subnets. Proxy
  # pods accept traffic only from these ranges.
  lb_newbits = 26 - tonumber(split("/", var.vpc_cidr)[1])
  lb_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, local.lb_newbits, 52 * pow(2, local.lb_newbits - 6) + i)]
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_vpc" "existing" {
  count = local.create_vpc ? 0 : 1
  id    = var.existing_vpc_id
}

data "aws_subnet" "existing_private" {
  count = local.create_vpc ? 0 : length(var.existing_private_subnet_ids)
  id    = var.existing_private_subnet_ids[count.index]
}

data "aws_subnet" "existing_lb" {
  count = local.create_vpc ? 0 : length(var.existing_lb_subnet_ids)
  id    = var.existing_lb_subnet_ids[count.index]
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 6.7.0"

  create_vpc = local.create_vpc

  name = var.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = local.private_subnets
  public_subnets  = local.public_subnets

  # "Intra" subnets have no route to the NAT gateways; internal load balancers
  # don't need one.
  intra_subnets       = local.lb_subnets
  intra_subnet_suffix = "lb"

  enable_nat_gateway     = true
  single_nat_gateway     = var.nat_gateway_mode == "single"
  one_nat_gateway_per_az = var.nat_gateway_mode == "one_per_az"

  enable_dns_hostnames = true
  enable_dns_support   = true

  map_public_ip_on_launch       = false
  manage_default_security_group = true

  # The proxy's load balancers are placed explicitly by Terraform. These tags
  # only matter for any other LoadBalancer Services the controller creates.
  public_subnet_tags = {
    "kubernetes.io/role/elb"            = "1"
    "kubernetes.io/cluster/${var.name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"   = "1"
    "kubernetes.io/cluster/${var.name}" = "shared"
  }

  tags = var.tags
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 6.7.0"

  create = local.create_vpc && var.enable_vpc_endpoints

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  create_security_group      = true
  security_group_name_prefix = "${var.name}-vpce-"
  security_group_description = "HTTPS from the VPC to interface endpoints"
  security_group_rules = {
    https_from_vpc = {
      description = "HTTPS from the VPC"
      cidr_blocks = [var.vpc_cidr]
    }
  }

  endpoints = {
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
      tags            = { Name = "${var.name}-s3" }
    }
    ecr_api = {
      service             = "ecr.api"
      private_dns_enabled = true
      tags                = { Name = "${var.name}-ecr-api" }
    }
    ecr_dkr = {
      service             = "ecr.dkr"
      private_dns_enabled = true
      tags                = { Name = "${var.name}-ecr-dkr" }
    }
    sts = {
      service             = "sts"
      private_dns_enabled = true
      tags                = { Name = "${var.name}-sts" }
    }
    logs = {
      service             = "logs"
      private_dns_enabled = true
      tags                = { Name = "${var.name}-logs" }
    }
  }

  tags = var.tags
}

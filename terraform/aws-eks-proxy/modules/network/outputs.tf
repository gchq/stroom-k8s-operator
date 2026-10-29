output "vpc_id" {
  description = "ID of the VPC."
  value       = local.create_vpc ? module.vpc.vpc_id : var.existing_vpc_id
}

output "vpc_cidr" {
  description = "Primary CIDR block of the VPC."
  value       = local.create_vpc ? module.vpc.vpc_cidr_block : data.aws_vpc.existing[0].cidr_block
}

output "private_subnet_ids" {
  description = "Private subnet IDs, one per AZ, for nodes and pods."
  value       = local.create_vpc ? module.vpc.private_subnets : var.existing_private_subnet_ids

  precondition {
    # Each proxy colour gets one node group per private subnet, which only
    # covers every AZ if the subnets are in different AZs.
    condition     = local.create_vpc || length(distinct(data.aws_subnet.existing_private[*].availability_zone)) == length(var.existing_private_subnet_ids)
    error_message = "existing_private_subnet_ids must be in different availability zones (one subnet per AZ)."
  }
}

output "public_subnet_ids" {
  description = "Public subnet IDs, for NAT gateways and internet-facing NLBs."
  value       = local.create_vpc ? module.vpc.public_subnets : var.existing_public_subnet_ids
}

output "lb_subnet_ids" {
  description = "Subnets for the ALB and the internal NLBs only."
  value       = local.create_vpc ? module.vpc.intra_subnets : var.existing_lb_subnet_ids

  precondition {
    condition     = local.create_vpc || length(distinct(data.aws_subnet.existing_lb[*].availability_zone)) == length(var.existing_lb_subnet_ids)
    error_message = "existing_lb_subnet_ids must be in different availability zones (one subnet per AZ)."
  }

  precondition {
    # An ALB needs at least a /27 with 8 free addresses in each subnet.
    condition     = local.create_vpc || alltrue([for s in data.aws_subnet.existing_lb : tonumber(split("/", s.cidr_block)[1]) <= 27])
    error_message = "Each of existing_lb_subnet_ids must be a /27 or larger."
  }
}

output "lb_subnet_cidrs" {
  description = "CIDR blocks of the lb subnets. The proxy NetworkPolicy allows ingress only from these."
  value       = local.create_vpc ? module.vpc.intra_subnets_cidr_blocks : data.aws_subnet.existing_lb[*].cidr_block
}

output "nat_public_ips" {
  description = "Public IPs of the NAT gateways (the source address of outbound traffic). Empty for an existing VPC."
  value       = local.create_vpc ? module.vpc.nat_public_ips : []
}

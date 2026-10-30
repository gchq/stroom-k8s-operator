# Read by the 20-platform and 30-stroom-proxy stacks through
# terraform_remote_state.

output "aws_region" {
  description = "AWS region of the deployment."
  value       = var.aws_region
}

output "name" {
  description = "Name of the deployment."
  value       = var.name
}

output "cluster_name" {
  description = "Name of the EKS cluster."
  value       = module.eks.cluster_name
}

output "cluster_endpoint" {
  description = "Endpoint of the Kubernetes API."
  value       = module.eks.cluster_endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate of the Kubernetes API."
  value       = module.eks.cluster_certificate_authority_data
}

output "cluster_version" {
  description = "Kubernetes version of the control plane."
  value       = module.eks.cluster_version
}

output "kubeconfig_command" {
  description = "Command that adds the cluster to your kubeconfig."
  value       = "aws eks update-kubeconfig --region ${var.aws_region} --name ${module.eks.cluster_name}"
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "Primary CIDR block of the VPC."
  value       = module.network.vpc_cidr
}

output "private_subnet_ids" {
  description = "Private subnet IDs."
  value       = module.network.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = module.network.public_subnet_ids
}

output "lb_subnet_ids" {
  description = "Subnets for the ALB and the internal NLBs only."
  value       = module.network.lb_subnet_ids
}

output "lb_subnet_cidrs" {
  description = "CIDR blocks of the lb subnets (the only sources allowed to reach proxy pods)."
  value       = module.network.lb_subnet_cidrs
}

output "nat_public_ips" {
  description = "Public IPs of the NAT gateways (source address of outbound traffic, e.g. to a downstream Stroom)."
  value       = module.network.nat_public_ips
}

output "node_security_group_id" {
  description = "Security group shared by all nodes."
  value       = module.eks.node_security_group_id
}

output "cluster_security_group_id" {
  description = "Security group of the control plane."
  value       = module.eks.cluster_security_group_id
}

output "cluster_primary_security_group_id" {
  description = "Security group EKS created for the cluster."
  value       = module.eks.cluster_primary_security_group_id
}

output "proxy_node_label" {
  description = "Label on all proxy nodes."
  value       = module.eks.proxy_node_label
}

output "proxy_node_colours" {
  description = "Proxy node colours: node label, node counts and node groups per colour (nodeSelector for each colour's proxy pods)."
  value       = module.eks.proxy_node_colours
}

output "proxy_node_taint" {
  description = "Taint on proxy nodes (proxy pods must tolerate it)."
  value       = module.eks.proxy_node_taint
}

output "system_node_label" {
  description = "Label on system nodes (nodeSelector for cluster services)."
  value       = module.eks.system_node_label
}

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

output "cluster_security_group_id" {
  description = "Security group of the control plane, created by the module."
  value       = module.eks.cluster_security_group_id
}

output "cluster_primary_security_group_id" {
  description = "Security group EKS created for the cluster."
  value       = module.eks.cluster_primary_security_group_id
}

output "node_security_group_id" {
  description = "Security group shared by all nodes. Phase 4 adds the proxy ingress rules to it."
  value       = module.eks.node_security_group_id
}

output "kms_key_arn" {
  description = "KMS key used for envelope encryption of Kubernetes Secrets."
  value       = module.eks.kms_key_arn
}

output "proxy_node_label" {
  description = "Label (key and value) on all proxy nodes."
  value       = local.proxy_node_label
}

output "proxy_node_colours" {
  description = "Proxy node colours: for each, the label that selects its nodes, its node count and its node groups. 30-stroom-proxy pins each colour's pods to its nodes."
  value = {
    for colour_name, colour in var.proxy_node_colours : colour_name => {
      node_label         = { key = local.colour_label_key, value = colour_name }
      nodes_per_az       = colour.nodes_per_az
      node_count         = colour.nodes_per_az * length(var.private_subnet_ids)
      instance_types     = colour.instance_types
      kubernetes_version = colour.kubernetes_version
      node_groups        = sort([for k, g in local.proxy_node_groups : k if g.colour_name == colour_name])
    }
  }
}

output "proxy_node_taint" {
  description = "Taint on proxy nodes. Proxy pods must tolerate it."
  value       = { key = local.proxy_node_label.key, value = local.proxy_node_label.value, effect = "NoSchedule" }
}

output "system_node_label" {
  description = "Label (key and value) on system nodes, for cluster services."
  value       = local.system_node_label
}

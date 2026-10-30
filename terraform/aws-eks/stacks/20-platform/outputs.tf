# Read by the 30-stroom-proxy stack through terraform_remote_state.

output "storage_class_name" {
  description = "Name of the default gp3 StorageClass."
  value       = module.platform.storage_class_name
}

output "external_secrets_namespace" {
  description = "Namespace of the External Secrets Operator."
  value       = module.platform.external_secrets_namespace
}

output "external_secrets_role_arn" {
  description = "IAM role of the External Secrets Operator."
  value       = module.platform.external_secrets_role_arn
}

output "secrets_name_prefix" {
  description = "Secrets Manager name prefix the External Secrets Operator may read. Create the proxy's secrets under it."
  value       = module.platform.secrets_name_prefix
}

output "lb_controller_role_arn" {
  description = "IAM role of the AWS Load Balancer Controller."
  value       = module.platform.lb_controller_role_arn
}

output "container_insights_log_groups" {
  description = "Container Insights log group names, by type."
  value       = module.platform.container_insights_log_groups
}

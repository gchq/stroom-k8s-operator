output "storage_class_name" {
  description = "Name of the default gp3 StorageClass."
  value       = kubernetes_storage_class_v1.gp3.metadata[0].name
}

output "lb_controller_role_arn" {
  description = "IAM role of the AWS Load Balancer Controller."
  value       = aws_iam_role.lb_controller.arn
}

output "external_secrets_namespace" {
  description = "Namespace of the External Secrets Operator."
  value       = local.external_secrets_namespace
}

output "external_secrets_role_arn" {
  description = "IAM role of the External Secrets Operator (reads secrets under secrets_name_prefix)."
  value       = aws_iam_role.external_secrets.arn
}

output "secrets_name_prefix" {
  description = "Secrets Manager name prefix the External Secrets Operator may read."
  value       = var.secrets_name_prefix
}

output "container_insights_log_groups" {
  description = "Container Insights log group names, by type."
  value       = { for k, g in aws_cloudwatch_log_group.container_insights : k => g.name }
}

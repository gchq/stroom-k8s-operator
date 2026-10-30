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
  description = "IAM role of the External Secrets Operator. It reads no secrets itself: workload roles named <cluster>-* that trust it are assumed per SecretStore."
  value       = aws_iam_role.external_secrets.arn
}

output "secrets_name_prefix" {
  description = "Secrets Manager name prefix of the deployment's secrets. Workload roles grant read access under it."
  value       = var.secrets_name_prefix
}

output "container_insights_log_groups" {
  description = "Container Insights log group names, by type."
  value       = { for k, g in aws_cloudwatch_log_group.container_insights : k => g.name }
}

output "stroom_enabled" {
  description = "Whether the Stroom components are installed."
  value       = var.stroom_enabled
}

output "internal_ca" {
  description = "The in-cluster CA, when Stroom is installed: the ClusterIssuer that signs workload certificates, and the ConfigMap (name and key) trust-manager writes its certificate to in every namespace with the label."
  value = var.stroom_enabled ? {
    cluster_issuer  = var.internal_ca_name
    configmap_name  = var.internal_ca_name
    configmap_key   = "ca.crt"
    namespace_label = var.internal_ca_namespace_label
  } : null
}

output "stroom_operator_namespace" {
  description = "Namespace of the Stroom operator, when Stroom is installed."
  value       = var.stroom_enabled ? local.stroom_operator_namespace : null
}

output "url" {
  description = "URL of the Stroom UI and API."
  value       = "https://${var.hostname}"
}

output "redirect_uri" {
  description = "Redirect URI to register with the identity provider."
  value       = "https://${var.hostname}/api/auth/flow/v1/signin-oidc"
}

output "alb_dns_name" {
  description = "DNS name of the internal ALB (alias target for the host name)."
  value       = aws_lb.stroom.dns_name
}

output "namespace" {
  description = "Kubernetes namespace of Stroom."
  value       = kubernetes_namespace_v1.stroom.metadata[0].name
}

output "stroom_role_arn" {
  description = "IAM role of the Stroom pods. A data bucket in another account must grant it read access (design 4.4)."
  value       = aws_iam_role.stroom.arn
}

output "node_names" {
  description = "Stroom node names, by node set. Permanent."
  value       = { for k, s in var.node_sets : k => [for i in range(s.count) : "${local.node_set_names[k]}-${i}"] }
}

output "frontend_service" {
  description = "In-cluster Service of the Frontend node set (HTTPS on 8443): the proxy's downstream host for receipt rules (design 8.1)."
  value       = "${local.http_services[local.frontend_node_set]}.${var.namespace}.svc.cluster.local"
}

output "proxy_api_key_secret_name" {
  description = "Secrets Manager name (relative to secrets_name_prefix) of the proxy's Stroom API key, written by the bootstrap Job. null without a proxy."
  value       = var.proxy_api_key_secret_name
}

output "bootstrap_job" {
  description = "Name of the bootstrap Job: a new name means it runs again. null while the cluster is stopped, when there is none."
  value       = one(kubernetes_job_v1.bootstrap[*].metadata[0].name)
}

output "db_init_job" {
  description = "Name of the database init Job: a new name means it runs again."
  value       = kubernetes_job_v1.db_init.metadata[0].name
}

output "external_secrets_role_arn" {
  description = "IAM role the SecretStore in Stroom's namespace assumes to read Stroom's secrets."
  value       = aws_iam_role.external_secrets.arn
}

output "stream_volume" {
  description = "EFS file system and access point of the shared stream volume."
  value = {
    file_system_id  = aws_efs_file_system.stream.id
    access_point_id = aws_efs_access_point.stream.id
  }
}

output "stroom_config" {
  description = "The rendered Stroom config.yml, for inspection."
  value       = local.stroom_config
}

output "stroom_cluster_spec" {
  description = "The StroomCluster spec, for inspection and tests."
  value       = local.stroom_cluster_spec
}

output "stroom_cluster_manifest" {
  description = "The StroomCluster manifest (YAML), for inspection and for checking against the CRD with kubectl --dry-run=server."
  value = yamlencode({
    apiVersion = "stroom.gchq.github.io/v1"
    kind       = "StroomCluster"
    metadata   = { name = var.cluster_resource_name, namespace = var.namespace }
    spec       = local.stroom_cluster_spec
  })
}

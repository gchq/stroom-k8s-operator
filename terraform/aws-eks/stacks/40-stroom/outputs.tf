output "url" {
  description = "URL of the Stroom UI and API."
  value       = module.stroom.url
}

output "redirect_uri" {
  description = "Redirect URI to register with the identity provider."
  value       = module.stroom.redirect_uri
}

output "alb_dns_name" {
  description = "DNS name of the internal ALB."
  value       = module.stroom.alb_dns_name
}

output "node_names" {
  description = "Stroom node names, by node set."
  value       = module.stroom.node_names
}

output "stroom_role_arn" {
  description = "IAM role of the Stroom pods; a bucket in another account grants it read access."
  value       = module.stroom.stroom_role_arn
}

# For the second 30-stroom-proxy apply (design 4.3): stroom_downstream
output "proxy_downstream" {
  description = "What the proxy needs for receipt rules from Stroom: the Frontend Service, the API key's secret and the in-cluster CA's ConfigMap. null without a proxy."
  value = var.proxy_state == null ? null : {
    hostname            = module.stroom.frontend_service
    port                = 8443
    api_key_secret_name = module.stroom.proxy_api_key_secret_name
    ca_bundle_configmap = local.platform.internal_ca.configmap_name
  }
}

output "database" {
  description = "The database: host, the secrets of its master and Stroom users, and the generation of the Stroom user's password."
  value = {
    host                      = module.stroom_db.host
    master_user_secret_arn    = module.stroom_db.master_user_secret_arn
    app_user_secret_name      = module.stroom_db.app_user_secret_name
    app_user_password_version = module.stroom_db.app_user_password_version
  }
}

output "external_secrets_role_arn" {
  description = "IAM role the SecretStore in Stroom's namespace assumes; 20-platform's External Secrets controller may assume it."
  value       = module.stroom.external_secrets_role_arn
}

output "stream_volume" {
  description = "EFS file system and access point of the shared stream volume."
  value       = module.stroom.stream_volume
}

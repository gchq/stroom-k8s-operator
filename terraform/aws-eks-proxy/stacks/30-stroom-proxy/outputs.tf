output "endpoints" {
  description = "Per endpoint (plain, mtls): datafeed URL, NLB DNS name, PrivateLink endpoint service name and private DNS verification record."
  value       = module.stroom_proxy.endpoints
}

output "alb_dns_name" {
  description = "DNS name of the internal ALB."
  value       = module.stroom_proxy.alb_dns_name
}

output "active_colour" {
  description = "Colour receiving traffic."
  value       = module.stroom_proxy.active_colour
}

output "listener_colours" {
  description = "Which colour each ALB listener forwards to (endpoints: active; test listeners :9443/:9444: inactive)."
  value       = module.stroom_proxy.listener_colours
}

output "target_group_arns" {
  description = "ALB target group per colour."
  value       = module.stroom_proxy.target_group_arns
}

output "data_bucket" {
  description = "Data bucket (Object Lock COMPLIANCE)."
  value       = module.stroom_proxy.data_bucket
}

output "data_events_queue_url" {
  description = "SQS queue announcing new data objects."
  value       = module.stroom_proxy.data_events_queue_url
}

output "receipt_config_bucket" {
  description = "Bucket for the DFK files and the client CA bundle."
  value       = module.stroom_proxy.receipt_config_bucket
}

output "proxy_role_arn" {
  description = "IAM role of the proxy pods."
  value       = module.stroom_proxy.proxy_role_arn
}

output "namespace" {
  description = "Kubernetes namespace of the proxies."
  value       = module.stroom_proxy.namespace
}

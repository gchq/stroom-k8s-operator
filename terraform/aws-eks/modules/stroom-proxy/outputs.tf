output "endpoints" {
  description = "Per endpoint (plain, mtls): datafeed URL, NLB DNS name, and the PrivateLink endpoint service name and private DNS verification record (if enabled)."
  value = {
    for k, e in local.endpoints : k => {
      datafeed_url     = "https://${e.hostname}/datafeed"
      nlb_dns_name     = aws_lb.nlb[k].dns_name
      endpoint_service = try(aws_vpc_endpoint_service.proxy[k].service_name, null)
      private_dns_verification = try({
        name  = "${aws_vpc_endpoint_service.proxy[k].private_dns_name_configuration[0].name}.${e.hostname}"
        type  = aws_vpc_endpoint_service.proxy[k].private_dns_name_configuration[0].type
        value = aws_vpc_endpoint_service.proxy[k].private_dns_name_configuration[0].value
      }, null)
    }
  }
}

output "alb_dns_name" {
  description = "DNS name of the internal ALB."
  value       = aws_lb.alb.dns_name
}

output "active_colour" {
  description = "Colour receiving traffic."
  value       = var.active_colour
}

output "listener_colours" {
  description = "Which colour each ALB listener forwards to: the endpoints (plain, mtls) to the active colour, the test listeners (test_plain :9444, test_mtls :9443) to the inactive one."
  value = merge(
    { for k in keys(local.endpoints) : k => var.active_colour },
    { for k, t in local.test_listeners : "test_${k}" => t.colour },
  )
}

output "target_group_arns" {
  description = "ALB target group per colour."
  value       = { for c, tg in aws_lb_target_group.proxy : c => tg.arn }
}

output "data_bucket" {
  description = "Data bucket (Object Lock COMPLIANCE) the proxies forward to."
  value       = local.data_bucket_name
}

output "data_events_queue_url" {
  description = "SQS queue announcing new data objects, if data_notifications = \"sqs\"."
  value       = try(aws_sqs_queue.data_events[0].url, null)
}

output "receipt_config_bucket" {
  description = "Bucket holding the DFK files (dfk prefix) and the client CA bundle."
  value       = local.receipt_config_bucket_name
}

output "client_ca_bundle_sha256" {
  description = "SHA-256 of the client CA bundle Terraform uploaded (null if it was already in an existing bucket), to confirm which bundle is deployed."
  value       = var.auth.client_ca_bundle_pem == null ? null : sha256(var.auth.client_ca_bundle_pem)
}

output "imported_certificate_sha256" {
  description = "SHA-256 of the server certificate imported for acm_imported (null otherwise), to confirm which certificate is deployed."
  value       = var.tls_certificate_source == "acm_imported" ? try(nonsensitive(sha256(var.imported_certificate.certificate_pem)), null) : null
}

output "proxy_role_arn" {
  description = "IAM role of the proxy pods (Pod Identity)."
  value       = aws_iam_role.proxy.arn
}

output "secrets_role_arn" {
  description = "IAM role External Secrets assumes to read the proxy's secrets. null when the proxy has none."
  value       = one(aws_iam_role.external_secrets[*].arn)
}

output "helm_values" {
  description = "The Helm values rendered for each colour's release (YAML), for inspection."
  value       = { for c, v in local.helm_values : c => yamlencode(v) }
}

output "namespace" {
  description = "Kubernetes namespace of the proxies."
  value       = kubernetes_namespace_v1.proxy.metadata[0].name
}

output "data_events_queue_arn" {
  description = "ARN of the SQS queue announcing new data objects, or null without one."
  value       = try(aws_sqs_queue.data_events[0].arn, null)
}

output "data_events_dlq_url" {
  description = "SQS dead-letter queue for data events that couldn't be processed, or null without one."
  value       = try(aws_sqs_queue.data_events_dlq[0].url, null)
}

output "data_events_dlq_arn" {
  description = "ARN of the dead-letter queue, or null without one."
  value       = try(aws_sqs_queue.data_events_dlq[0].arn, null)
}

output "data_bucket_kms_key_arn" {
  description = "KMS key that encrypts the data bucket, or null for SSE-S3."
  value       = local.data_kms_key_arn
}

output "data_retention_days" {
  description = "Object Lock retention of the data bucket, in days."
  value       = var.data_retention_days
}

output "data_expire_after_days" {
  description = "Days after which the data bucket's lifecycle rule deletes objects, or null if this stack doesn't expire them (never, or the bucket is managed elsewhere, whose own rules then apply). A downstream Stroom's raw data retention must not be longer."
  value       = local.create_data_bucket && var.data_expire_after_retention ? var.data_retention_days + 1 : null
}

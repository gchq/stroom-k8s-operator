################################################################################
# Namespace and network policy
################################################################################

resource "kubernetes_namespace_v1" "proxy" {
  metadata {
    name = var.namespace
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
      # Readiness gates: a pod is only Ready once healthy in its target group
      # (section 9.3).
      "elbv2.k8s.aws/pod-readiness-gate-inject" = "enabled"
    }
  }
}

# Only the load balancers (in the lb subnets) may reach the proxies: the proxy
# trusts the ALB's DN header from whoever sends it (F14, section 5.3).
resource "kubernetes_network_policy_v1" "proxy" {
  metadata {
    name      = "stroom-proxy-ingress"
    namespace = kubernetes_namespace_v1.proxy.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "stroom-proxy" }
    }
    policy_types = ["Ingress"]

    ingress {
      dynamic "from" {
        for_each = var.lb_subnet_cidrs
        content {
          ip_block {
            cidr = from.value
          }
        }
      }

      dynamic "ports" {
        for_each = local.ports
        content {
          protocol = "TCP"
          port     = tostring(ports.value)
        }
      }
    }
  }
}

################################################################################
# Secrets from Secrets Manager (External Secrets Operator, 20-platform)
################################################################################

resource "kubernetes_manifest" "secret_store" {
  count = length(local.proxy_secrets) > 0 ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "SecretStore"
    metadata = {
      name      = "secrets-manager"
      namespace = kubernetes_namespace_v1.proxy.metadata[0].name
    }
    spec = {
      provider = {
        aws = {
          service = "SecretsManager"
          region  = var.aws_region
        }
      }
    }
  }
}

resource "kubernetes_manifest" "proxy_secrets" {
  count = length(local.proxy_secrets) > 0 ? 1 : 0

  manifest = {
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata = {
      name      = local.proxy_secret_name
      namespace = kubernetes_namespace_v1.proxy.metadata[0].name
    }
    spec = {
      refreshInterval = "1h"
      secretStoreRef = {
        name = kubernetes_manifest.secret_store[0].manifest.metadata.name
        kind = "SecretStore"
      }
      target = {
        name           = local.proxy_secret_name
        creationPolicy = "Owner"
      }
      # Env var name => secret name under secrets_name_prefix.
      data = [
        for env_name, secret_name in local.proxy_secrets : {
          secretKey = env_name
          remoteRef = { key = "${var.secrets_name_prefix}${secret_name}" }
        }
      ]
    }
  }
}

################################################################################
# Per colour: TargetGroupBinding and the Helm release
################################################################################

# Registers the colour's pods in its ALB target group. Created before the
# release, so the pods get readiness gates when they are created.
resource "kubernetes_manifest" "target_group_binding" {
  for_each = var.proxy_deployments

  manifest = {
    apiVersion = "elbv2.k8s.aws/v1beta1"
    kind       = "TargetGroupBinding"
    metadata = {
      name      = local.service_name[each.key]
      namespace = kubernetes_namespace_v1.proxy.metadata[0].name
    }
    spec = {
      targetGroupARN = aws_lb_target_group.proxy[each.key].arn
      targetType     = "ip"
      serviceRef = {
        name = local.service_name[each.key]
        port = local.ports.https
      }
    }
  }
}

resource "helm_release" "proxy" {
  for_each = var.proxy_deployments

  name      = local.service_name[each.key]
  namespace = kubernetes_namespace_v1.proxy.metadata[0].name

  repository = var.chart_path == null ? var.chart_repository : null
  chart      = var.chart_path == null ? "stroom-proxy" : var.chart_path
  version    = var.chart_path == null ? var.chart_version : null

  values = [
    yamlencode(local.helm_values[each.key]),
    # Deep-merged over the first document by Helm.
    yamlencode({ proxyConfig = var.extra_proxy_config }),
  ]

  # Wait for the pods to be Ready, which includes being healthy in the target
  # group (readiness gates).
  wait    = true
  timeout = 900

  depends_on = [
    terraform_data.input_checks,
    terraform_data.existing_data_bucket_check,
    kubernetes_network_policy_v1.proxy,
    kubernetes_manifest.proxy_secrets,
    kubernetes_manifest.target_group_binding,
    # A target group only health-checks its pods once a listener uses it:
    # without the listeners, the readiness gates (and so the wait) never pass.
    aws_lb_listener.plain,
    aws_lb_listener.mtls,
    aws_lb_listener.test,
    time_sleep.pod_identity_propagation,
    aws_iam_role_policy.proxy,
    aws_vpc_security_group_ingress_rule.pods_from_alb,
    aws_s3_bucket_policy.data,
    aws_s3_bucket_object_lock_configuration.data,
  ]
}

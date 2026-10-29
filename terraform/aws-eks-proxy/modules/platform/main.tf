locals {
  system_node_selector = { (var.system_node_label.key) = var.system_node_label.value }

  lb_controller_namespace       = "kube-system"
  lb_controller_service_account = "aws-load-balancer-controller"

  external_secrets_namespace       = "external-secrets"
  external_secrets_service_account = "external-secrets"

  cloudwatch_namespace       = "amazon-cloudwatch"
  cloudwatch_service_account = "cloudwatch-agent"

  # Log groups the CloudWatch Observability add-on writes to. Created here
  # first so they get a retention period; the add-on would otherwise create
  # them with logs kept forever.
  container_insights_log_groups = toset(["application", "dataplane", "host", "performance"])
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

# Trust policy shared by every Pod Identity role in this module.
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

################################################################################
# AWS Load Balancer Controller
#
# Used only for TargetGroupBinding: it registers proxy pod IPs in the ALB
# target groups that 30-stroom-proxy creates, and injects the pod readiness
# gates. Ingress classes and the Service mutator are turned off.
################################################################################

resource "aws_iam_role" "lb_controller" {
  name_prefix        = "${var.cluster_name}-lbc-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

resource "aws_iam_policy" "lb_controller" {
  name_prefix = "${var.cluster_name}-lbc-"
  description = "AWS Load Balancer Controller ${var.lb_controller_chart_version}"
  policy      = file("${path.module}/lb-controller-iam-policy.json")
  tags        = var.tags
}

resource "aws_iam_role_policy_attachment" "lb_controller" {
  role       = aws_iam_role.lb_controller.name
  policy_arn = aws_iam_policy.lb_controller.arn
}

resource "aws_eks_pod_identity_association" "lb_controller" {
  cluster_name    = var.cluster_name
  namespace       = local.lb_controller_namespace
  service_account = local.lb_controller_service_account
  role_arn        = aws_iam_role.lb_controller.arn
  tags            = var.tags
}

resource "helm_release" "lb_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = var.lb_controller_chart_version
  namespace  = local.lb_controller_namespace

  wait    = true
  timeout = 600

  values = [yamlencode({
    clusterName = var.cluster_name
    region      = var.aws_region
    vpcId       = var.vpc_id

    serviceAccount = {
      create = true
      name   = local.lb_controller_service_account
    }

    # The controller's webhook injects readiness gates into pods in namespaces
    # labelled for it (only the proxy namespace). Fail rather than create a
    # proxy pod without its gate, which would let a rolling restart move on
    # before the replacement is healthy in its target group. Two replicas and
    # a PDB keep the webhook available.
    podMutatorWebhookConfig = { failurePolicy = "Fail" }
    replicaCount            = 2
    podDisruptionBudget     = { maxUnavailable = 1 }
    nodeSelector            = local.system_node_selector

    createIngressClassResource  = false
    enableServiceMutatorWebhook = false
  })]

  depends_on = [
    aws_eks_pod_identity_association.lb_controller,
    aws_iam_role_policy_attachment.lb_controller,
  ]
}

################################################################################
# gp3 StorageClass (default)
################################################################################

resource "kubernetes_storage_class_v1" "gp3" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  volume_binding_mode    = "WaitForFirstConsumer"
  allow_volume_expansion = true
  reclaim_policy         = "Delete"

  parameters = merge(
    {
      type       = "gp3"
      encrypted  = "true"
      iops       = tostring(var.gp3_iops)
      throughput = tostring(var.gp3_throughput)
    },
    var.ebs_kms_key_arn == null ? {} : { kmsKeyId = var.ebs_kms_key_arn },
  )
}

################################################################################
# CloudWatch Observability add-on (Fluent Bit container logs, Container Insights)
#
# Its pods tolerate all taints by default (add-on 1.7.0 and later), so Fluent
# Bit also runs on the tainted proxy nodes.
################################################################################

resource "aws_cloudwatch_log_group" "container_insights" {
  for_each = local.container_insights_log_groups

  name              = "/aws/containerinsights/${var.cluster_name}/${each.key}"
  retention_in_days = var.log_retention_days
  kms_key_id        = var.log_kms_key_arn
  tags              = var.tags
}

resource "aws_iam_role" "cloudwatch" {
  name_prefix        = "${var.cluster_name}-cw-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "cloudwatch" {
  role       = aws_iam_role.cloudwatch.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_eks_addon" "cloudwatch" {
  cluster_name  = var.cluster_name
  addon_name    = "amazon-cloudwatch-observability"
  addon_version = var.cloudwatch_addon_version

  pod_identity_association {
    service_account = local.cloudwatch_service_account
    role_arn        = aws_iam_role.cloudwatch.arn
  }

  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = var.tags

  depends_on = [
    aws_cloudwatch_log_group.container_insights,
    aws_iam_role_policy_attachment.cloudwatch,
  ]
}

################################################################################
# External Secrets Operator
#
# Reads Secrets Manager secrets under secrets_name_prefix only. The
# SecretStore itself is created by 30-stroom-proxy, in the proxy namespace:
# its CRD only exists once this release is installed, and Terraform can't plan
# a custom resource before its CRD exists.
################################################################################

resource "aws_iam_role" "external_secrets" {
  name_prefix        = "${var.cluster_name}-eso-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid       = "ReadProxySecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = ["arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.secrets_name_prefix}*"]
  }

  statement {
    sid       = "DecryptViaSecretsManager"
    actions   = ["kms:Decrypt"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-proxy-secrets"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

resource "aws_eks_pod_identity_association" "external_secrets" {
  cluster_name    = var.cluster_name
  namespace       = local.external_secrets_namespace
  service_account = local.external_secrets_service_account
  role_arn        = aws_iam_role.external_secrets.arn
  tags            = var.tags
}

resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = var.external_secrets_chart_version
  namespace        = local.external_secrets_namespace
  create_namespace = true

  wait    = true
  timeout = 600

  values = [yamlencode({
    installCRDs = true
    global = {
      nodeSelector = local.system_node_selector
    }
    serviceAccount = {
      create = true
      name   = local.external_secrets_service_account
    }
  })]

  depends_on = [
    aws_eks_pod_identity_association.external_secrets,
    aws_iam_role_policy.external_secrets,
  ]
}

################################################################################
# Proxy role (EKS Pod Identity): add objects to the data bucket, read the DFK
# files. Shared by every colour; one association per colour's service account.
################################################################################

data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "proxy" {
  name_prefix        = "${var.name}-proxy-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "proxy" {
  # Add objects only: no read, delete, retention, legal hold or bucket
  # configuration. The forwarder tags each object with its feed and stream
  # type in the PutObject request itself (F11), but S3 still requires
  # s3:PutObjectTagging for tags given at upload. The same permission lets the
  # role retag the current version of an existing object; tags aren't the
  # data, and Object Lock still protects the data.
  statement {
    sid = "AddDataObjects"
    actions = [
      "s3:PutObject",
      "s3:PutObjectTagging",
      "s3:AbortMultipartUpload",
      "s3:ListMultipartUploadParts",
    ]
    resources = ["${local.data_bucket_arn}/*"]
  }

  dynamic "statement" {
    # (Not "local.data_kms_key_arn == null": the new key's ARN is only known
    # after apply, which would leave the whole policy unknown at plan time.)
    for_each = local.create_data_bucket || var.data_bucket_kms_key_arn != null ? [1] : []
    content {
      # Decrypt is needed to complete multipart uploads; without s3:GetObject
      # it doesn't let the proxy read data. Only through S3, not directly.
      sid       = "EncryptDataObjects"
      actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
      resources = [local.data_kms_key_arn]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["s3.${var.aws_region}.amazonaws.com"]
      }
    }
  }

  dynamic "statement" {
    for_each = local.dfk_enabled ? [1] : []
    content {
      sid       = "ReadDataFeedKeys"
      actions   = ["s3:GetObject"]
      resources = ["${local.receipt_config_bucket_arn}/${var.auth.dfk_s3_prefix}*"]
    }
  }

  dynamic "statement" {
    for_each = local.dfk_enabled ? [1] : []
    content {
      sid       = "ListDataFeedKeys"
      actions   = ["s3:ListBucket"]
      resources = [local.receipt_config_bucket_arn]
      condition {
        test     = "StringLike"
        variable = "s3:prefix"
        values   = [var.auth.dfk_s3_prefix, "${var.auth.dfk_s3_prefix}*"]
      }
    }
  }
}

resource "aws_iam_role_policy" "proxy" {
  name   = "stroom-proxy"
  role   = aws_iam_role.proxy.id
  policy = data.aws_iam_policy_document.proxy.json
}

resource "aws_eks_pod_identity_association" "proxy" {
  for_each = var.proxy_deployments

  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = local.service_account_name[each.key]
  role_arn        = aws_iam_role.proxy.arn
  tags            = var.tags
}

# A new association takes a few seconds to reach the EKS Pod Identity webhook.
# Pods created before then get no credentials (no AWS_CONTAINER_CREDENTIALS_*
# variables) and stay that way until recreated: in dev, a new colour's
# dfk-sync init container failed with "Unable to locate credentials".
resource "time_sleep" "pod_identity_propagation" {
  for_each = var.proxy_deployments

  create_duration = "30s"
  triggers = {
    association_id = aws_eks_pod_identity_association.proxy[each.key].association_id
  }
}

################################################################################
# Role External Secrets assumes to read the proxy's secrets. The External
# Secrets controller's own role (20-platform) reads no secrets: it may only
# assume roles named "<cluster name>-*", and this role trusts only it.
################################################################################

locals {
  # Without the controller's role, input_checks reports what is missing.
  secrets_role_enabled = length(local.proxy_secrets) > 0 && var.external_secrets_role_arn != null

  # Exactly the proxy's secrets. Secrets Manager adds "-" and six random
  # characters to the name in a secret's ARN.
  proxy_secret_arns = [
    for name in distinct(values(local.proxy_secrets)) :
    "arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:${var.secrets_name_prefix}${name}-??????"
  ]
}

data "aws_iam_policy_document" "external_secrets_trust" {
  count = local.secrets_role_enabled ? 1 : 0

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = [var.external_secrets_role_arn]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  count = local.secrets_role_enabled ? 1 : 0

  # Must start with the cluster name (var.name: 10-infra names the cluster
  # after it), as the controller may only assume roles named that way.
  name_prefix        = "${var.name}-pxeso-"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_trust[0].json
  tags               = var.tags
}

data "aws_iam_policy_document" "external_secrets" {
  count = local.secrets_role_enabled ? 1 : 0

  statement {
    sid       = "ReadProxySecrets"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = local.proxy_secret_arns
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
  count = local.secrets_role_enabled ? 1 : 0

  name   = "read-proxy-secrets"
  role   = aws_iam_role.external_secrets[0].id
  policy = data.aws_iam_policy_document.external_secrets[0].json
}

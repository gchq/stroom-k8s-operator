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
  # configuration. Tagging is needed because the forwarder tags each object
  # with its feed and stream type (F11).
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
    for_each = local.data_kms_key_arn == null ? [] : [1]
    content {
      # Decrypt is needed to complete multipart uploads; without s3:GetObject
      # it doesn't let the proxy read data.
      sid       = "EncryptDataObjects"
      actions   = ["kms:GenerateDataKey", "kms:Decrypt"]
      resources = [local.data_kms_key_arn]
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

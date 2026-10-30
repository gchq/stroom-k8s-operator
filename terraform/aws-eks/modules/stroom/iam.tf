################################################################################
# Stroom's role (EKS Pod Identity, design 7.4): read the data bucket, consume
# its event queue, send refused events to the DLQ
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

resource "aws_iam_role" "stroom" {
  name_prefix        = "${var.name}-stroom-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "stroom" {
  # Read only: Stroom never writes or deletes the proxy's objects, which are
  # under Object Lock anyway (S4)
  statement {
    sid       = "ReadDataObjects"
    actions   = ["s3:GetObject"]
    resources = ["arn:${local.partition}:s3:::${var.ingest.bucket}/*"]
  }

  statement {
    sid       = "ListDataBucket"
    actions   = ["s3:ListBucket"]
    resources = ["arn:${local.partition}:s3:::${var.ingest.bucket}"]
  }

  statement {
    sid = "ConsumeDataEvents"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:ChangeMessageVisibility",
      "sqs:GetQueueAttributes",
      "sqs:GetQueueUrl",
    ]
    resources = [var.ingest.queue_arn]
  }

  statement {
    sid       = "RefuseDataEvents"
    actions   = ["sqs:SendMessage", "sqs:GetQueueUrl"]
    resources = [var.ingest.dlq_arn]
  }

  dynamic "statement" {
    for_each = var.ingest.kms_key_arn == null ? [] : [1]
    content {
      sid       = "DecryptDataObjects"
      actions   = ["kms:Decrypt"]
      resources = [var.ingest.kms_key_arn]
    }
  }
}

resource "aws_iam_role_policy" "stroom" {
  name   = "stroom"
  role   = aws_iam_role.stroom.id
  policy = data.aws_iam_policy_document.stroom.json
}

resource "aws_eks_pod_identity_association" "stroom" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = local.service_account_name
  role_arn        = aws_iam_role.stroom.arn
  tags            = var.tags
}

# A new association takes a few seconds to reach the Pod Identity webhook; pods
# created before then get no credentials (proxy design F27)
resource "time_sleep" "pod_identity_propagation" {
  create_duration = "30s"
  triggers = {
    stroom_association = aws_eks_pod_identity_association.stroom.association_id
    bootstrap          = aws_eks_pod_identity_association.bootstrap.association_id
  }
}

################################################################################
# Bootstrap Job's role (design 5.4): write the proxy's API key, nothing else
################################################################################

resource "aws_iam_role" "bootstrap" {
  name_prefix        = "${var.name}-stroom-boot-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "bootstrap" {
  statement {
    sid     = "WriteProxyApiKey"
    actions = ["secretsmanager:PutSecretValue", "secretsmanager:DescribeSecret"]
    # The secret is created here; null without a proxy, when the Job writes nothing
    resources = var.proxy_api_key_secret_name == null ? ["arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:none"] : [aws_secretsmanager_secret.proxy_api_key[0].arn]
  }
}

resource "aws_iam_role_policy" "bootstrap" {
  name   = "stroom-bootstrap"
  role   = aws_iam_role.bootstrap.id
  policy = data.aws_iam_policy_document.bootstrap.json
}

resource "aws_eks_pod_identity_association" "bootstrap" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = local.bootstrap_service_account
  role_arn        = aws_iam_role.bootstrap.arn
  tags            = var.tags
}

# The proxy's API key: created empty here, filled in by the bootstrap Job, and
# read by the proxy through External Secrets
resource "aws_secretsmanager_secret" "proxy_api_key" {
  count = var.proxy_api_key_secret_name == null ? 0 : 1

  name        = "${var.secrets_name_prefix}${var.proxy_api_key_secret_name}"
  description = "Stroom API key of the stroom-proxy user, for receipt rules (${var.name}). Written by the Stroom bootstrap Job."
  tags        = var.tags
}

################################################################################
# The External Secrets Operator may also read the RDS-managed master secret,
# which RDS names outside secrets_name_prefix. The database init Job uses it.
################################################################################

data "aws_iam_policy_document" "external_secrets_db_master" {
  statement {
    sid       = "ReadStroomDbMasterSecret"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.db.master_user_secret_arn]
  }

  statement {
    sid       = "DecryptStroomDbSecrets"
    actions   = ["kms:Decrypt"]
    resources = [var.db.kms_key_arn]
  }
}

resource "aws_iam_role_policy" "external_secrets_db_master" {
  name   = "${var.name}-stroom-db-master"
  role   = element(split("/", var.external_secrets_role_arn), length(split("/", var.external_secrets_role_arn)) - 1)
  policy = data.aws_iam_policy_document.external_secrets_db_master.json
}

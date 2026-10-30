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
    stroom_association    = aws_eks_pod_identity_association.stroom.association_id
    bootstrap             = aws_eks_pod_identity_association.bootstrap.association_id
    proxy_key_renewal     = join("", aws_eks_pod_identity_association.proxy_key_renewal[*].association_id)
    external_secrets_role = aws_iam_role_policy.external_secrets.id
  }
}

################################################################################
# Bootstrap Job's role (design 5.4): write the proxy's API key, nothing else
################################################################################

resource "aws_iam_role" "bootstrap" {
  name_prefix        = "${var.name}-stboot-"
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
# Proxy API key renewal CronJob's role (design 8.1): see when the current key
# was written, and write a new one. Nothing else.
################################################################################

resource "aws_iam_role" "proxy_key_renewal" {
  count = var.proxy_api_key_secret_name == null ? 0 : 1

  name_prefix        = "${var.name}-stkey-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

data "aws_iam_policy_document" "proxy_key_renewal" {
  count = var.proxy_api_key_secret_name == null ? 0 : 1

  statement {
    sid       = "RenewProxyApiKey"
    actions   = ["secretsmanager:ListSecretVersionIds", "secretsmanager:PutSecretValue"]
    resources = [aws_secretsmanager_secret.proxy_api_key[0].arn]
  }
}

resource "aws_iam_role_policy" "proxy_key_renewal" {
  count = var.proxy_api_key_secret_name == null ? 0 : 1

  name   = "stroom-proxy-key-renewal"
  role   = aws_iam_role.proxy_key_renewal[0].id
  policy = data.aws_iam_policy_document.proxy_key_renewal[0].json
}

resource "aws_eks_pod_identity_association" "proxy_key_renewal" {
  count = var.proxy_api_key_secret_name == null ? 0 : 1

  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = local.proxy_key_renewal_service_account
  role_arn        = aws_iam_role.proxy_key_renewal[0].arn
  tags            = var.tags
}

################################################################################
# External Secrets (design 13): the SecretStore in Stroom's namespace assumes
# this role, which reads Stroom's secrets only: the Stroom database user's
# password, the RDS-managed master secret (for the database init Job) and the
# OIDC client secret. The controller's own role (20-platform) reads nothing; it
# may only assume roles named <cluster_name>-*. Not the proxy's API key, which
# Stroom writes and only the proxy's namespace reads.
################################################################################

data "aws_iam_policy_document" "external_secrets_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "AWS"
      identifiers = [var.external_secrets_role_arn]
    }
  }
}

resource "aws_iam_role" "external_secrets" {
  name_prefix        = "${var.name}-steso-"
  description        = "External Secrets in the ${var.namespace} namespace: reads Stroom's secrets (${var.name})"
  assume_role_policy = data.aws_iam_policy_document.external_secrets_trust.json
  tags               = var.tags

  depends_on = [terraform_data.check_role_names]
}

locals {
  # Secrets Manager adds a hyphen and six random characters to a secret's name
  # to make its ARN
  oidc_client_secret_arn = "arn:${local.partition}:secretsmanager:${var.aws_region}:${local.account_id}:secret:${var.secrets_name_prefix}${var.idp.client_secret_name}-??????"
}

data "aws_iam_policy_document" "external_secrets" {
  statement {
    sid     = "ReadStroomSecrets"
    actions = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [
      var.db.app_user_secret_arn,
      var.db.master_user_secret_arn,
      local.oidc_client_secret_arn,
    ]
  }

  # The database key encrypts the Stroom user's password and the master secret;
  # a client secret under Secrets Manager's AWS managed key needs no grant
  statement {
    sid       = "DecryptStroomSecrets"
    actions   = ["kms:Decrypt"]
    resources = compact([var.db.kms_key_arn, var.idp.client_secret_kms_key_arn])
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.aws_region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "external_secrets" {
  name   = "read-stroom-secrets"
  role   = aws_iam_role.external_secrets.id
  policy = data.aws_iam_policy_document.external_secrets.json
}

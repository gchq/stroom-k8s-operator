################################################################################
# Data bucket: immutable once written (section 7.1)
################################################################################

locals {
  create_data_bucket = var.data_bucket_name == null
  data_bucket_name   = local.create_data_bucket ? aws_s3_bucket.data[0].bucket : var.data_bucket_name
  data_bucket_arn    = "arn:${local.partition}:s3:::${local.data_bucket_name}"
  data_kms_key_arn   = local.create_data_bucket ? aws_kms_key.data[0].arn : var.data_bucket_kms_key_arn

  create_receipt_config_bucket = var.receipt_config_bucket == null
  receipt_config_bucket_name   = local.create_receipt_config_bucket ? aws_s3_bucket.receipt_config[0].bucket : var.receipt_config_bucket
  receipt_config_bucket_arn    = "arn:${local.partition}:s3:::${local.receipt_config_bucket_name}"
}

data "aws_iam_policy_document" "data_key" {
  count = local.create_data_bucket ? 1 : 0

  statement {
    sid       = "AccountAdministersKeyThroughIam"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # Losing the key would make the locked data unreadable.
  statement {
    sid       = "OnlyLockAdminsDisableOrDeleteKey"
    effect    = "Deny"
    actions   = ["kms:ScheduleKeyDeletion", "kms:DisableKey"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = local.lock_admin_arns
    }
  }
}

resource "aws_kms_key" "data" {
  count = local.create_data_bucket ? 1 : 0

  description             = "Stroom-Proxy data bucket (${var.name})"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.data_key[0].json
  tags                    = var.tags

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_kms_alias" "data" {
  count = local.create_data_bucket ? 1 : 0

  name          = "alias/${var.name}-proxy-data"
  target_key_id = aws_kms_key.data[0].key_id
}

resource "aws_s3_bucket" "data" {
  count = local.create_data_bucket ? 1 : 0

  bucket              = "${var.name}-data-${local.account_id}-${var.aws_region}"
  object_lock_enabled = true
  tags                = var.tags

  # AWS won't delete a bucket holding locked objects anyway; this stops
  # Terraform trying. Remove the bucket from state to destroy the stack.
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "data" {
  count = local.create_data_bucket ? 1 : 0

  bucket = aws_s3_bucket.data[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_object_lock_configuration" "data" {
  count = local.create_data_bucket ? 1 : 0

  bucket = aws_s3_bucket.data[0].id
  rule {
    default_retention {
      mode = "COMPLIANCE"
      days = var.data_retention_days
    }
  }

  depends_on = [aws_s3_bucket_versioning.data]
}

resource "aws_s3_bucket_server_side_encryption_configuration" "data" {
  count = local.create_data_bucket ? 1 : 0

  bucket = aws_s3_bucket.data[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.data[0].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "data" {
  count = local.create_data_bucket ? 1 : 0

  bucket                  = aws_s3_bucket.data[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "data" {
  count = local.create_data_bucket ? 1 : 0

  bucket = aws_s3_bucket.data[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "data" {
  count = local.create_data_bucket ? 1 : 0

  bucket = aws_s3_bucket.data[0].id

  rule {
    id     = "abort-incomplete-multipart-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  dynamic "rule" {
    for_each = var.data_expire_after_retention ? [1] : []
    content {
      id     = "expire-after-retention"
      status = "Enabled"
      filter {}
      expiration {
        days = var.data_retention_days + 1
      }
      noncurrent_version_expiration {
        noncurrent_days = 1
      }
    }
  }

  depends_on = [aws_s3_bucket_versioning.data]
}

data "aws_iam_policy_document" "data_bucket" {
  count = local.create_data_bucket ? 1 : 0

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.data_bucket_arn, "${local.data_bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Backstop to the proxy role's IAM policy, which only allows adding objects.
  statement {
    sid    = "DenyProxyChangingData"
    effect = "Deny"
    actions = [
      "s3:Delete*",
      "s3:PutObjectRetention",
      "s3:PutObjectLegalHold",
      "s3:BypassGovernanceRetention",
      "s3:PutObjectAcl",
      "s3:PutObjectVersionAcl",
      "s3:PutBucket*",
      "s3:PutLifecycleConfiguration",
      "s3:PutEncryptionConfiguration",
      "s3:PutReplicationConfiguration",
    ]
    resources = [local.data_bucket_arn, "${local.data_bucket_arn}/*"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.proxy.arn]
    }
  }

  statement {
    sid       = "OnlyLockAdminsChangeObjectLock"
    effect    = "Deny"
    actions   = ["s3:PutBucketObjectLockConfiguration"]
    resources = [local.data_bucket_arn]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "ArnNotLike"
      variable = "aws:PrincipalArn"
      values   = local.lock_admin_arns
    }
  }
}

resource "aws_s3_bucket_policy" "data" {
  count = local.create_data_bucket ? 1 : 0

  bucket = aws_s3_bucket.data[0].id
  policy = data.aws_iam_policy_document.data_bucket[0].json

  depends_on = [aws_s3_bucket_public_access_block.data]
}

# An existing data bucket must already be locked down; the provider can't read
# Object Lock settings, so ask S3 through the AWS CLI.
data "external" "existing_data_bucket" {
  count   = local.create_data_bucket ? 0 : 1
  program = ["bash", "${path.module}/scripts/object-lock-status.sh"]
  query = {
    bucket = var.data_bucket_name
    region = var.aws_region
  }
}

resource "terraform_data" "existing_data_bucket_check" {
  count = local.create_data_bucket ? 0 : 1

  lifecycle {
    precondition {
      condition = (
        data.external.existing_data_bucket[0].result.versioning == "Enabled" &&
        data.external.existing_data_bucket[0].result.object_lock == "Enabled" &&
        data.external.existing_data_bucket[0].result.mode == "COMPLIANCE" &&
        data.external.existing_data_bucket[0].result.retention != ""
      )
      error_message = "data_bucket_name must have versioning, and Object Lock in COMPLIANCE mode with a default retention (found: ${jsonencode(data.external.existing_data_bucket[0].result)})."
    }
  }
}

################################################################################
# Notifications of new data objects (for Stroom's S3/SQS ingest)
################################################################################

locals {
  data_notifications = local.create_data_bucket && var.data_notifications == "sqs"
}

resource "aws_sqs_queue" "data_events_dlq" {
  count = local.data_notifications ? 1 : 0

  name                      = "${var.name}-data-events-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
  tags                      = var.tags
}

resource "aws_sqs_queue" "data_events" {
  count = local.data_notifications ? 1 : 0

  name                       = "${var.name}-data-events"
  message_retention_seconds  = 1209600
  visibility_timeout_seconds = 300
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.data_events_dlq[0].arn
    maxReceiveCount     = 5
  })
  tags = var.tags
}

data "aws_iam_policy_document" "data_events" {
  count = local.data_notifications ? 1 : 0

  statement {
    sid       = "S3Notifications"
    actions   = ["sqs:SendMessage"]
    resources = [aws_sqs_queue.data_events[0].arn]
    principals {
      type        = "Service"
      identifiers = ["s3.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [local.data_bucket_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_sqs_queue_policy" "data_events" {
  count = local.data_notifications ? 1 : 0

  queue_url = aws_sqs_queue.data_events[0].id
  policy    = data.aws_iam_policy_document.data_events[0].json
}

resource "aws_s3_bucket_notification" "data" {
  count = local.data_notifications ? 1 : 0

  bucket = aws_s3_bucket.data[0].id
  queue {
    queue_arn = aws_sqs_queue.data_events[0].arn
    events    = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sqs_queue_policy.data_events]
}

################################################################################
# Receipt config bucket: DFK files and the client CA bundle (section 7.2)
################################################################################

resource "aws_s3_bucket" "receipt_config" {
  count = local.create_receipt_config_bucket ? 1 : 0

  bucket = "${var.name}-rcfg-${local.account_id}-${var.aws_region}"
  tags   = var.tags
}

# Versioned, so the ALB trust store can refer to an exact PEM version.
resource "aws_s3_bucket_versioning" "receipt_config" {
  count = local.create_receipt_config_bucket ? 1 : 0

  bucket = aws_s3_bucket.receipt_config[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3, so the ALB trust store can read the PEM without a KMS grant.
resource "aws_s3_bucket_server_side_encryption_configuration" "receipt_config" {
  count = local.create_receipt_config_bucket ? 1 : 0

  bucket = aws_s3_bucket.receipt_config[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "receipt_config" {
  count = local.create_receipt_config_bucket ? 1 : 0

  bucket                  = aws_s3_bucket.receipt_config[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "receipt_config" {
  count = local.create_receipt_config_bucket ? 1 : 0

  bucket = aws_s3_bucket.receipt_config[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "receipt_config_bucket" {
  count = local.create_receipt_config_bucket ? 1 : 0

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [local.receipt_config_bucket_arn, "${local.receipt_config_bucket_arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "receipt_config" {
  count = local.create_receipt_config_bucket ? 1 : 0

  bucket = aws_s3_bucket.receipt_config[0].id
  policy = data.aws_iam_policy_document.receipt_config_bucket[0].json

  depends_on = [aws_s3_bucket_public_access_block.receipt_config]
}

# The client CA bundle, when given as an input. Otherwise it must already be
# in an existing receipt config bucket.
resource "aws_s3_object" "client_ca_bundle" {
  count = local.mtls_enabled && var.auth.client_ca_bundle_pem != null ? 1 : 0

  bucket       = local.receipt_config_bucket_name
  key          = var.auth.trust_store_pem_s3_key
  content      = var.auth.client_ca_bundle_pem
  content_type = "application/x-pem-file"
  tags         = var.tags

  depends_on = [aws_s3_bucket_versioning.receipt_config]
}

data "aws_s3_object" "client_ca_bundle" {
  count = local.mtls_enabled && var.auth.client_ca_bundle_pem == null ? 1 : 0

  bucket = local.receipt_config_bucket_name
  key    = var.auth.trust_store_pem_s3_key
}

data "aws_s3_object" "client_crl" {
  for_each = local.mtls_enabled ? toset(var.auth.client_crl_s3_keys) : toset([])

  bucket = local.receipt_config_bucket_name
  key    = each.value
}

locals {
  client_ca_bundle_version = !local.mtls_enabled ? null : (
    var.auth.client_ca_bundle_pem != null ? aws_s3_object.client_ca_bundle[0].version_id : data.aws_s3_object.client_ca_bundle[0].version_id
  )
}

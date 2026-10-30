################################################################################
# Plan-time checks across inputs, one resource per rule so that a test can
# expect exactly the rule it breaks. Everything that creates or changes Stroom
# depends on input_checks, which depends on them all, so a failed check stops
# the plan before any change.
################################################################################

# Stroom's raw streams are the bucket's objects (design 7.3): once S3 has
# expired one, Stroom can't read the stream.
resource "terraform_data" "check_retention" {
  lifecycle {
    precondition {
      condition     = var.ingest.expire_after_days == null ? true : var.raw_data_retention_days < var.ingest.expire_after_days
      error_message = "raw_data_retention_days (${var.raw_data_retention_days}) must be less than the data bucket's expiry (${coalesce(var.ingest.expire_after_days, 0)} days): S3 would delete objects Stroom still holds streams for. Lengthen the bucket's retention, or shorten Stroom's."
    }
  }
}

# Each node set runs on its own node groups from 10-infra (design 11.2)
resource "terraform_data" "check_node_groups" {
  lifecycle {
    precondition {
      condition     = alltrue([for k in keys(var.node_sets) : contains(keys(var.stroom_node_sets), k)])
      error_message = "Every node set needs Stroom node groups of the same name in 10-infra's stroom_node_sets (${join(", ", keys(var.stroom_node_sets))})."
    }
  }
}

# One Stroom pod per node
resource "terraform_data" "check_node_counts" {
  lifecycle {
    precondition {
      condition     = alltrue([for k, s in var.node_sets : contains(keys(var.stroom_node_sets), k) ? s.count <= var.stroom_node_sets[k].node_count : true])
      error_message = "A node set's count is more than its nodes in 10-infra (one Stroom pod per node): raise stroom_node_sets.<set>.node_count in 10-infra first."
    }
  }
}

# What each tls_certificate_source needs
resource "terraform_data" "check_tls_source" {
  lifecycle {
    precondition {
      condition     = var.tls_certificate_source != "acm_private_ca" || var.private_ca_arn != null
      error_message = "tls_certificate_source = \"acm_private_ca\" needs private_ca_arn."
    }

    precondition {
      condition     = var.tls_certificate_source != "acm_public" || var.route53_zone_id != null
      error_message = "tls_certificate_source = \"acm_public\" needs route53_zone_id, for DNS validation."
    }

    precondition {
      condition     = var.tls_certificate_source != "acm_existing" || var.certificate_arn != null
      error_message = "tls_certificate_source = \"acm_existing\" needs certificate_arn."
    }

    precondition {
      condition     = var.tls_certificate_source != "acm_imported" || nonsensitive(var.imported_certificate != null)
      error_message = "tls_certificate_source = \"acm_imported\" needs imported_certificate."
    }
  }
}

# External Secrets' controller may only assume roles named <cluster_name>-*
# (20-platform), so Stroom's External Secrets role must be named that way
resource "terraform_data" "check_role_names" {
  lifecycle {
    precondition {
      condition     = startswith("${var.name}-", "${var.cluster_name}-")
      error_message = "name (${var.name}) must be cluster_name (${var.cluster_name}) or start with \"${var.cluster_name}-\": External Secrets may only assume roles named <cluster_name>-*."
    }
  }
}

# What the rest of the module depends on
resource "terraform_data" "input_checks" {
  input = {
    node_sets = keys(var.node_sets)
  }

  depends_on = [
    terraform_data.check_retention,
    terraform_data.check_node_groups,
    terraform_data.check_node_counts,
    terraform_data.check_tls_source,
    terraform_data.check_role_names,
  ]
}

# Copy envs/example to envs/<env> and adjust. Needs 10-infra with
# stroom_node_sets, and 20-platform applied after it.

# Must match envs/<env>/backend-*.hcl.
infra_state = {
  bucket = "my-terraform-state-bucket"
  key    = "stroom-proxy/example/10-infra.tfstate"
  region = "eu-west-2"
}
platform_state = {
  bucket = "my-terraform-state-bucket"
  key    = "stroom-proxy/example/20-platform.tfstate"
  region = "eu-west-2"
}
# The proxy in this cluster, whose data bucket Stroom ingests from. null for a
# Stroom-only cluster: then set ingest below.
proxy_state = {
  bucket = "my-terraform-state-bucket"
  key    = "stroom-proxy/example/30-stroom-proxy.tfstate"
  region = "eu-west-2"
}

# --- Stroom ---
# Node names are <prefix>-<node set>-<n>, e.g. stroom-example-proc-0. The
# prefix and node set names are permanent; counts may only grow.
node_name_prefix = "stroom-example"
stroom_image = {
  repository = "gchq/stroom"
  tag        = "v7.14.0"
  digest     = null # recommended: "sha256:..."
}
stopped = false # true stops every node for a version upgrade (design section 12)

# Keys and counts must match 10-infra's stroom_node_sets (one pod per node).
node_sets = {
  # cpu leaves about 3 vCPUs per node for DaemonSets and the operator's API key Job,
  # which runs next to a Stroom pod.
  proc = { count = 2, role = "Processing", cpu = 29, memory_gib = 240, heap_gib = 64, data_volume_gb = 1000 }
  ui   = { count = 1, role = "Frontend", cpu = 13, memory_gib = 120, heap_gib = 64, data_volume_gb = 200 }
}
extra_jvm_opts = [] # e.g. ["-XX:+UseZGC"]

stream_volume = { type = "efs", throughput_mode = "elastic", backup = true }

database = {
  instance_class        = "db.r6g.large"
  multi_az              = true
  storage_gb            = 200
  max_storage_gb        = 1000
  backup_retention_days = 14
  deletion_protection   = true
  max_connections       = 1000
  # Raise (2, 3, ...) to give the Stroom database user a new password: the
  # init Job sets it (the old one stays valid until the next change) and the
  # Stroom nodes restart one at a time with it.
  app_user_password_version = 1
}

# --- authentication: the app registration is made outside Terraform ---
# Register the redirect URI https://<hostname>/api/auth/flow/v1/signin-oidc,
# and put the client secret in Secrets Manager under 20-platform's
# secrets_name_prefix.
idp = {
  type               = "entra" # entra | keycloak | cognito
  tenant_id          = "00000000-0000-0000-0000-000000000000"
  discovery_url      = null # derived for entra
  client_id          = "11111111-1111-1111-1111-111111111111"
  client_secret_name = "stroom-oidc-client-secret"
  # The client secret's KMS key, if a customer managed one (null: Secrets
  # Manager's AWS managed key). Stroom's External Secrets role may decrypt with it.
  client_secret_kms_key_arn = null
  first_admin = {
    subject      = "22222222-2222-2222-2222-222222222222" # the admin's Entra object ID (oid)
    display_name = "First Admin"
  }
}

# --- ingest ---
# The longest Stroom retention rule for raw streams; less than the bucket's expiry.
raw_data_retention_days = 60
# For a Stroom-only cluster (proxy_state = null), the bucket managed elsewhere:
# ingest = {
#   bucket            = "other-data-bucket"
#   queue_url         = "https://sqs.eu-west-2.amazonaws.com/444455556666/other-data-events"
#   queue_arn         = "arn:aws:sqs:eu-west-2:444455556666:other-data-events"
#   dlq_url           = "https://sqs.eu-west-2.amazonaws.com/444455556666/other-data-events-dlq"
#   dlq_arn           = "arn:aws:sqs:eu-west-2:444455556666:other-data-events-dlq"
#   kms_key_arn       = null
#   expire_after_days = null
# }

# --- access ---
hostname               = "stroom.example.internal"
allowed_ingress_cidrs  = ["10.0.0.0/8"]
route53_zone_id        = null
tls_certificate_source = "acm_private_ca" # acm_private_ca | acm_public | acm_existing | acm_imported
private_ca_arn         = "arn:aws:acm-pca:eu-west-2:123456789012:certificate-authority/REPLACE_ME"

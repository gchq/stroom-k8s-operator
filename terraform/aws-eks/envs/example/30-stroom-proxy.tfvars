# Copy envs/example to envs/<env> and adjust.

# Must match envs/<env>/backend-10-infra.hcl and backend-20-platform.hcl.
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

# Can change Object Lock settings and disable/delete the data bucket's KMS key
# (besides the identity running Terraform).
admin_principal_arns = [] # e.g. ["arn:aws:iam::123456789012:role/PlatformAdmin"]

# --- Proxies: one colour normally, two during a blue/green upgrade ---
# Each colour needs proxy nodes of the same colour (proxy_node_colours in
# 10-infra), and no more replicas than it has nodes.
proxy_deployments = {
  blue = {
    image_tag    = "v7.14-beta.8"
    image_digest = "sha256:f729b691b7001dbf7d2b99fcae9d6c150c99fddd0840f4f3375f43edb34ff68f"
    replicas     = 3
  }
}
active_colour = "blue"

proxy_resources = {
  requests = { cpu = "1", memory = "4Gi" }
  limits   = { cpu = "2", memory = "4Gi" }
}
proxy_data_volume_gb = 200

# --- Endpoints ---
load_balancer_scheme  = "internal"
allowed_ingress_cidrs = ["10.0.0.0/8"]                # senders on the private network (VPN, peering, Direct Connect)
hostname              = "proxy.example.internal"      # tokens and data feed keys
mtls_hostname         = "mtls.proxy.example.internal" # client certificates
route53_zone_id       = null                          # e.g. "Z0123456789"

tls_certificate_source = "acm_private_ca" # acm_private_ca | acm_public | acm_existing
private_ca_arn         = "arn:aws:acm-pca:eu-west-2:123456789012:certificate-authority/00000000-0000-0000-0000-000000000000"

privatelink = {
  enabled              = false
  allowed_principals   = [] # e.g. ["arn:aws:iam::210987654321:root"]
  acceptance_required  = true
  verification_zone_id = null # public zone for the TXT records that verify the private DNS names
}

# --- Authentication ---
auth = {
  types = ["CERTIFICATE", "TOKEN", "DATA_FEED_KEY"]
  # The client CA bundle for mTLS (required with certificate auth). Terraform
  # uploads it to the receipt config bucket. Alternatively set it to null and
  # set receipt_config_bucket to an existing bucket that already holds it.
  client_ca_bundle_pem   = <<-EOT
    -----BEGIN CERTIFICATE-----
    REPLACE WITH THE CA CERTIFICATES THAT ISSUE SENDERS' CLIENT CERTIFICATES
    -----END CERTIFICATE-----
  EOT
  trust_store_pem_s3_key = "trust/client-ca.pem"
  dfk_s3_prefix          = "dfk/" # DataFeedIdentities JSON files go here
  openid = {
    issuer            = "https://login.example.com/realms/stroom"
    allowed_audiences = ["stroom-proxy"]
    client_id         = "stroom-proxy"
  }
}

downstream = null # optional downstream Stroom
receipt    = { check_mode = "RECEIVE_ALL" }

# --- Data bucket (Object Lock COMPLIANCE: retention can't be shortened) ---
data_retention_days         = 1 # set per environment
data_expire_after_retention = false
data_notifications          = "sqs"

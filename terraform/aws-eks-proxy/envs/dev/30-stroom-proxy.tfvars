infra_state = {
  bucket = "REPLACE_ME-terraform-state"
  key    = "stroom-proxy/dev/10-infra.tfstate"
  region = "eu-west-2"
}
platform_state = {
  bucket = "REPLACE_ME-terraform-state"
  key    = "stroom-proxy/dev/20-platform.tfstate"
  region = "eu-west-2"
}

proxy_deployments = {
  blue = {
    image_tag    = "v7.14-beta.8"
    image_digest = "sha256:f729b691b7001dbf7d2b99fcae9d6c150c99fddd0840f4f3375f43edb34ff68f"
    replicas     = 3
  }
}
active_colour = "blue"

proxy_resources = {
  requests = { cpu = "500m", memory = "3Gi" }
  limits   = { cpu = "1500m", memory = "3Gi" }
}
proxy_data_volume_gb = 20

# Who sends test data, and who may use the test listeners (:9443/:9444).
# Usually the same machine: "<its IP or network>/32".
allowed_ingress_cidrs = ["REPLACE_ME/32"]
admin_cidrs           = ["REPLACE_ME/32"]

hostname        = "proxy.dev.REPLACE_ME"
mtls_hostname   = "mtls.proxy.dev.REPLACE_ME"
route53_zone_id = null # set to create the DNS records; otherwise use the endpoints output

# One of:
tls_certificate_source = "acm_private_ca"
private_ca_arn         = "REPLACE_ME"
# tls_certificate_source = "acm_public"   # needs route53_zone_id (public zone)

privatelink = {
  enabled = false # turn on for the PrivateLink tests (needs a second VPC/account)
}

# Throwaway CA from scripts/make-test-certs.sh envs/dev/test-certs
client_ca_bundle_pem_file = "../../envs/dev/test-certs/client-ca.pem"

auth = {
  # TOKEN needs an IdP: add it, with openid = {...}, for the token tests.
  types         = ["CERTIFICATE", "DATA_FEED_KEY"]
  dfk_s3_prefix = "dfk/"
}

receipt = { check_mode = "RECEIVE_ALL" }

# Dev: test data is locked for this long and can't be deleted sooner.
data_retention_days         = 1
data_expire_after_retention = true
data_notifications          = "sqs"

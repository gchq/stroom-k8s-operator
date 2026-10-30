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

# The chart from this checkout (it isn't published yet). Relative to the stack.
chart_path = "../../../../charts/stroom-proxy"

proxy_resources = {
  requests = { cpu = "500m", memory = "3Gi" }
  limits   = { cpu = "1500m", memory = "3Gi" }
}
proxy_data_volume_gb = 20

# Who sends test data, and who may use the test listeners (:9443/:9444).
# Usually the same machine: "<its IP or network>/32".
# Internet-facing NLBs, so a machine outside the VPC can send test data; still
# limited to allowed_ingress_cidrs. (The ALB, and so its test listeners, stays
# internal: test those from inside the VPC.)
load_balancer_scheme  = "internet-facing"
allowed_ingress_cidrs = ["REPLACE_ME/32"]
admin_cidrs           = ["REPLACE_ME/32"]

# Made-up names, no DNS: tests reach the NLBs with curl --resolve. They must
# match the server certificate from scripts/make-test-certs.sh.
hostname        = "proxy.dev.test"
mtls_hostname   = "mtls.proxy.dev.test"
route53_zone_id = null

# Server certificate signed by the throwaway test server CA, imported into ACM.
# With a real domain, use acm_public and route53_zone_id instead.
tls_certificate_source = "acm_imported"
imported_certificate_files = {
  certificate = "../../envs/dev/test-certs/server.pem"
  private_key = "../../envs/dev/test-certs/server.key"
}

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

# Dev: also log the identity headers the ALB passes, so the receive log shows
# which DN the proxy was given (RemoteDN is empty behind the ALB: the TLS
# session ends there). The list replaces the proxy's default metaKeys.
extra_proxy_config = {
  logStream = {
    metaKeys = [
      "guid", "receiptid", "feed", "system", "environment",
      "remotehost", "remoteaddress", "remotedn", "remotecertexpiry",
      "x-stroom-mtls-subject", "x-amzn-mtls-clientcert-subject",
    ]
  }
}

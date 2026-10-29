# Plan-only tests of modules/stroom-proxy with mocked providers.
#
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012", arn = "arn:aws:sts::123456789012:assumed-role/terraform/session" }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::123456789012:role/terraform" }
  }
  mock_data "aws_s3_object" {
    defaults = { version_id = "v1" }
  }
  mock_resource "aws_vpc_endpoint_service" {
    defaults = {
      service_name = "com.amazonaws.vpce.eu-west-2.vpce-svc-0123456789abcdef0"
      private_dns_name_configuration = [{
        name  = "_vpce-verify"
        type  = "TXT"
        value = "vpce:abc"
        state = "pendingVerification"
      }]
    }
  }
}

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "external" {}

variables {
  # As 10-infra and 20-platform would output them.
  name                   = "stroom-proxy-test"
  cluster_name           = "stroom-proxy-test"
  aws_region             = "eu-west-2"
  vpc_id                 = "vpc-0123456789abcdef0"
  vpc_cidr               = "10.40.0.0/16"
  lb_subnet_ids          = ["subnet-lb-a", "subnet-lb-b", "subnet-lb-c"]
  lb_subnet_cidrs        = ["10.40.208.0/26", "10.40.208.64/26", "10.40.208.128/26"]
  public_subnet_ids      = ["subnet-pub-a", "subnet-pub-b", "subnet-pub-c"]
  node_security_group_id = "sg-0123456789abcdef0"
  proxy_node_colours = {
    blue  = { node_label = { key = "stroom-proxy/colour", value = "blue" }, node_count = 3 }
    green = { node_label = { key = "stroom-proxy/colour", value = "green" }, node_count = 3 }
  }
  secrets_name_prefix = "stroom-proxy/test/"
  storage_class_name  = "gp3"

  proxy_deployments = {
    blue = {
      image_tag    = "v7.14-beta.8"
      image_digest = "sha256:f729b691b7001dbf7d2b99fcae9d6c150c99fddd0840f4f3375f43edb34ff68f"
      replicas     = 3
    }
  }
  active_colour         = "blue"
  allowed_ingress_cidrs = ["10.0.0.0/8"]
  hostname              = "proxy.example.internal"
  mtls_hostname         = "mtls.proxy.example.internal"
  private_ca_arn        = "arn:aws:acm-pca:eu-west-2:123456789012:certificate-authority/abc"
  data_retention_days   = 30
  auth = {
    client_ca_bundle_pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
    openid = {
      issuer            = "https://login.example.com/realms/stroom"
      allowed_audiences = ["stroom-proxy"]
      client_id         = "stroom-proxy"
    }
  }
}

################################################################################
# What gets built
################################################################################

run "default_deployment" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  # Proxy config and Helm values.
  assert {
    condition     = yamldecode(helm_release.proxy["blue"].values[0]).proxyConfig.forwardS3Destinations[0].client.keyPattern == "$${type}/$${year}/$${month}/$${day}/$${feed}/$${uuid}.zip"
    error_message = "The S3 key template must default to one with $${uuid} (F18)."
  }

  assert {
    condition     = yamldecode(helm_release.proxy["blue"].values[0]).proxyConfig.receive.enabledAuthenticationTypes == ["CERTIFICATE", "TOKEN", "DATA_FEED_KEY"]
    error_message = "Expected certificate, token and DFK authentication by default."
  }

  assert {
    condition     = yamldecode(helm_release.proxy["blue"].values[0]).proxyConfig.receive.x509CertificateDnHeader == "X-Stroom-Mtls-Subject"
    error_message = "The proxy must read the DN from the ALB's renamed header."
  }

  assert {
    condition     = yamldecode(helm_release.proxy["blue"].values[0]).proxyConfig.proxyId == "stroom-proxy-test-$${POD_NAME}"
    error_message = "Each pod needs its own proxy ID."
  }

  assert {
    condition     = yamldecode(helm_release.proxy["blue"].values[0]).proxyConfig.downstreamHost.enabled == false && yamldecode(helm_release.proxy["blue"].values[0]).proxyConfig.receive.receiptCheckMode == "RECEIVE_ALL"
    error_message = "No downstream by default."
  }

  assert {
    condition     = yamldecode(helm_release.proxy["blue"].values[0]).proxyConfig.security.authentication.openId.identityProviderType == "EXTERNAL_IDP"
    error_message = "OpenID should be configured for an external IdP."
  }

  assert {
    condition     = yamldecode(helm_release.proxy["blue"].values[0]).proxyConfig.security.authentication.openId.allowedAudiences == ["stroom-proxy"] && yamldecode(helm_release.proxy["blue"].values[0]).proxyConfig.downstreamHost.enabled == false && yamldecode(helm_release.proxy["blue"].values[0]).proxyConfig.aggregator.maxItemsPerAggregate == 1000
    error_message = "proxyConfig must keep its types (lists, booleans, numbers), not be stringified."
  }

  assert {
    condition     = yamldecode(helm_release.proxy["blue"].values[0]).dfkSync.enabled == true && yamldecode(helm_release.proxy["blue"].values[0]).dfkSync.prefix == "dfk/"
    error_message = "DFK sync should be on, from dfk/."
  }

  assert {
    condition     = tostring(yamldecode(helm_release.proxy["blue"].values[0]).drain.deregistrationDelaySeconds) == aws_lb_target_group.proxy["blue"].deregistration_delay
    error_message = "The chart's drain wait must match the target group's deregistration delay."
  }

  assert {
    condition     = yamldecode(helm_release.proxy["blue"].values[0]).healthCheckPath == aws_lb_target_group.proxy["blue"].health_check[0].path
    error_message = "Probes and target group health checks must use the same path."
  }

  # Load balancers.
  assert {
    condition     = aws_lb.alb.internal == true && aws_lb.alb.xff_header_processing_mode == "remove"
    error_message = "The ALB must be internal and remove X-Forwarded-For (F19)."
  }

  assert {
    condition     = length(aws_lb.nlb) == 2 && length(aws_lb_listener.mtls) == 1
    error_message = "Expected two NLBs and an mTLS listener."
  }

  assert {
    condition     = aws_lb_listener.mtls[0].mutual_authentication[0].mode == "verify" && aws_lb_listener.mtls[0].routing_http_request_x_amzn_mtls_clientcert_subject_header_name == "X-Stroom-Mtls-Subject"
    error_message = "The mTLS listener must verify certificates and rename the subject header."
  }

  assert {
    condition     = contains(keys(aws_lb_listener_rule.plain_reject_dn_headers), "X-Stroom-Mtls-Subject") && alltrue([for r in aws_lb_listener_rule.plain_reject_dn_headers : r.action[0].fixed_response[0].status_code == "403"])
    error_message = "The plain listener must reject requests carrying DN headers (F14)."
  }

  assert {
    condition     = aws_lb_target_group.nlb_to_alb["mtls"].health_check[0].port == "443" && aws_lb_target_group.nlb_to_alb["mtls"].port == 8443
    error_message = "The mTLS NLB must forward to 8443 but health-check the plain listener."
  }

  assert {
    condition     = aws_lb_trust_store.clients[0].ca_certificates_bundle_s3_key == "trust/client-ca.pem"
    error_message = "The trust store must come from the client CA bundle in S3."
  }

  assert {
    condition     = length(aws_vpc_endpoint_service.proxy) == 0
    error_message = "No endpoint services unless PrivateLink is enabled."
  }

  # Data bucket.
  assert {
    condition     = aws_s3_bucket.data[0].object_lock_enabled == true && aws_s3_bucket_object_lock_configuration.data[0].rule[0].default_retention[0].mode == "COMPLIANCE" && aws_s3_bucket_object_lock_configuration.data[0].rule[0].default_retention[0].days == 30
    error_message = "The data bucket must have Object Lock in COMPLIANCE mode with the retention given."
  }

  assert {
    condition     = length(aws_sqs_queue.data_events) == 1 && length(aws_s3_bucket_notification.data) == 1
    error_message = "New data objects should be announced on SQS."
  }

  # Kubernetes.
  assert {
    condition     = kubernetes_namespace_v1.proxy.metadata[0].labels["pod-security.kubernetes.io/enforce"] == "restricted" && kubernetes_namespace_v1.proxy.metadata[0].labels["elbv2.k8s.aws/pod-readiness-gate-inject"] == "enabled"
    error_message = "The namespace must enforce restricted PSS and inject readiness gates."
  }

  assert {
    condition     = length(kubernetes_network_policy_v1.proxy.spec[0].ingress[0].from) == 3
    error_message = "The NetworkPolicy must allow only the lb subnets."
  }

  assert {
    condition     = kubernetes_manifest.target_group_binding["blue"].manifest.spec.serviceRef.name == "stroom-proxy-blue"
    error_message = "The TargetGroupBinding must refer to the chart's Service."
  }

  assert {
    condition     = length(kubernetes_manifest.secret_store) == 0
    error_message = "No SecretStore when there are no secrets."
  }
}

run "privatelink" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    privatelink = {
      enabled            = true
      allowed_principals = ["arn:aws:iam::210987654321:root"]
    }
  }

  assert {
    condition     = length(aws_vpc_endpoint_service.proxy) == 2 && aws_vpc_endpoint_service.proxy["mtls"].private_dns_name == "mtls.proxy.example.internal" && aws_vpc_endpoint_service.proxy["plain"].private_dns_name == "proxy.example.internal"
    error_message = "Expected an endpoint service per NLB, with the endpoints' host names."
  }

  assert {
    condition     = alltrue([for nlb in aws_lb.nlb : nlb.enforce_security_group_inbound_rules_on_private_link_traffic == "off"])
    error_message = "PrivateLink traffic is controlled by the endpoint services, not the NLB security groups."
  }
}

run "no_certificate_auth" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    auth = {
      types = ["TOKEN", "DATA_FEED_KEY"]
      openid = {
        issuer            = "https://login.example.com/realms/stroom"
        allowed_audiences = ["stroom-proxy"]
        client_id         = "stroom-proxy"
      }
    }
  }

  assert {
    condition     = length(aws_lb.nlb) == 1 && length(aws_lb_listener.mtls) == 0 && length(aws_lb_trust_store.clients) == 0
    error_message = "Without certificate auth there is no mTLS listener, NLB or trust store."
  }
}

run "downstream_and_secrets" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    downstream = {
      hostname            = "stroom.example.internal"
      api_key_secret_name = "downstream-api-key"
    }
    receipt = { check_mode = "RECEIPT_POLICY" }
  }

  assert {
    condition     = yamldecode(helm_release.proxy["blue"].values[0]).proxyConfig.downstreamHost.apiKey == "$${DOWNSTREAM_API_KEY}" && yamldecode(helm_release.proxy["blue"].values[0]).extraEnvFrom[0].secretRef.name == "stroom-proxy-secrets"
    error_message = "The downstream API key must come from the synced secret."
  }

  assert {
    # Numbers and booleans, not strings (a conditional between differently
    # shaped objects would turn them into strings).
    condition     = yamldecode(helm_release.proxy["blue"].values[0]).proxyConfig.downstreamHost.port == 443 && yamldecode(helm_release.proxy["blue"].values[0]).proxyConfig.downstreamHost.enabled == true
    error_message = "downstreamHost must keep its types (port a number, enabled a boolean)."
  }

  assert {
    condition     = kubernetes_manifest.proxy_secrets[0].manifest.spec.data[0].remoteRef.key == "stroom-proxy/test/downstream-api-key"
    error_message = "Secrets must be read from under the secrets prefix."
  }
}

run "blue_green" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    proxy_deployments = {
      blue  = { image_tag = "v7.14-beta.8", image_digest = "sha256:f729b691b7001dbf7d2b99fcae9d6c150c99fddd0840f4f3375f43edb34ff68f", replicas = 3 }
      green = { image_tag = "v7.14.0", image_digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000", replicas = 3 }
    }
    active_colour = "green"
  }

  assert {
    condition     = length(aws_lb_target_group.proxy) == 2 && length(helm_release.proxy) == 2 && length(aws_eks_pod_identity_association.proxy) == 2
    error_message = "Each colour needs its own target group, release and Pod Identity association."
  }

  # The inactive colour's target group must be used by a listener, or its
  # health checks (and so its pods' readiness gates) never run.
  assert {
    condition     = aws_lb_listener.test["mtls"].port == 9443 && aws_lb_listener.test["plain"].port == 9444
    error_message = "Expected test listeners on :9443 (mTLS) and :9444 (plain)."
  }

  assert {
    condition     = output.listener_colours == { mtls = "green", plain = "green", test_mtls = "blue", test_plain = "blue" }
    error_message = "The main listeners must forward to the active colour (green), the test listeners to the inactive one (blue)."
  }

  assert {
    condition     = length(aws_lb_listener_rule.test_plain_reject_dn_headers) == 4
    error_message = "The plain test listener must reject DN headers too."
  }
}

run "single_colour_has_no_test_listeners" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  assert {
    condition     = length(aws_lb_listener.test) == 0
    error_message = "No test listeners with only one colour."
  }
}

run "existing_data_bucket" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    data_bucket_name = "existing-locked-bucket"
  }

  override_data {
    target = data.external.existing_data_bucket[0]
    values = { result = { versioning = "Enabled", object_lock = "Enabled", mode = "COMPLIANCE", retention = "365" } }
  }

  assert {
    condition     = length(aws_s3_bucket.data) == 0 && yamldecode(helm_release.proxy["blue"].values[0]).proxyConfig.forwardS3Destinations[0].client.bucketName == "existing-locked-bucket"
    error_message = "An existing data bucket should be used, not created."
  }
}

################################################################################
# What gets rejected
################################################################################

run "rejects_existing_bucket_without_compliance_lock" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    data_bucket_name = "unlocked-bucket"
  }

  override_data {
    target = data.external.existing_data_bucket[0]
    values = { result = { versioning = "Enabled", object_lock = "Enabled", mode = "GOVERNANCE", retention = "365" } }
  }

  expect_failures = [terraform_data.existing_data_bucket_check]
}

run "rejects_missing_digest" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    proxy_deployments = { blue = { image_tag = "v7.14-LATEST", image_digest = "", replicas = 3 } }
  }

  expect_failures = [var.proxy_deployments]
}

run "rejects_unknown_active_colour" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    active_colour = "green"
  }

  expect_failures = [var.active_colour]
}

run "rejects_key_template_without_unique_id" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    forward_s3 = { key_template = "$${type}/$${feed}/data.zip" }
  }

  expect_failures = [var.forward_s3]
}

run "rejects_token_without_idp_or_downstream" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    auth = {
      client_ca_bundle_pem = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
    }
  }

  expect_failures = [terraform_data.input_checks]
}

run "rejects_receipt_policy_without_downstream" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    receipt = { check_mode = "RECEIPT_POLICY" }
  }

  expect_failures = [terraform_data.input_checks]
}

run "rejects_more_replicas_than_nodes" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    proxy_deployments = { blue = { image_tag = "v7.14-beta.8", image_digest = "sha256:f729b691b7001dbf7d2b99fcae9d6c150c99fddd0840f4f3375f43edb34ff68f", replicas = 4 } }
  }

  expect_failures = [terraform_data.input_checks]
}

run "rejects_colour_without_nodes" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    proxy_deployments = { red = { image_tag = "v7.14-beta.8", image_digest = "sha256:f729b691b7001dbf7d2b99fcae9d6c150c99fddd0840f4f3375f43edb34ff68f", replicas = 3 } }
    active_colour     = "red"
  }

  expect_failures = [terraform_data.input_checks]
}

run "rejects_certificate_auth_without_ca_bundle" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    auth = {
      openid = {
        issuer            = "https://login.example.com/realms/stroom"
        allowed_audiences = ["stroom-proxy"]
        client_id         = "stroom-proxy"
      }
    }
  }

  expect_failures = [terraform_data.input_checks]
}

run "rejects_internet_facing_open_to_all" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    load_balancer_scheme  = "internet-facing"
    allowed_ingress_cidrs = ["0.0.0.0/0"]
  }

  expect_failures = [terraform_data.input_checks]
}

run "rejects_same_hostnames" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    mtls_hostname = "proxy.example.internal"
  }

  expect_failures = [var.mtls_hostname]
}

run "rejects_zero_retention" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    data_retention_days = 0
  }

  expect_failures = [var.data_retention_days]
}

run "rejects_privatelink_without_principals" {
  command = plan

  module {
    source = "../../modules/stroom-proxy"
  }

  variables {
    privatelink = { enabled = true }
  }

  expect_failures = [terraform_data.input_checks]
}

# The stack's wiring: remote state, the deployment shapes (with the proxy, or
# Stroom only with a bucket managed elsewhere) and the stack checks. Plan-only,
# against mocked providers.
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
    defaults = { account_id = "123456789012" }
  }
}
mock_provider "kubernetes" {}
# random is real: mocks don't support ephemeral resources, and it needs no credentials
mock_provider "time" {}
mock_provider "http" {
  mock_data "http" {
    defaults = {
      status_code   = 200
      response_body = "-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n"
    }
  }
}

override_data {
  target = data.terraform_remote_state.infra
  values = {
    outputs = {
      aws_region                         = "eu-west-2"
      name                               = "stroom-test"
      cluster_name                       = "stroom-test"
      cluster_endpoint                   = "https://example.eks.amazonaws.com"
      cluster_certificate_authority_data = "Y2VydA=="
      vpc_id                             = "vpc-0123456789abcdef0"
      private_subnet_ids                 = ["subnet-a", "subnet-b", "subnet-c"]
      lb_subnet_ids                      = ["subnet-d", "subnet-e", "subnet-f"]
      lb_subnet_cidrs                    = ["10.40.208.0/26", "10.40.208.64/26", "10.40.208.128/26"]
      node_security_group_id             = "sg-nodes"
      stroom_node_taint                  = { key = "workload", value = "stroom", effect = "NoSchedule" }
      stroom_node_sets = {
        proc = { node_label = { key = "stroom/node-set", value = "proc" }, node_count = 2 }
        ui   = { node_label = { key = "stroom/node-set", value = "ui" }, node_count = 1 }
      }
    }
  }
}

override_data {
  target = data.terraform_remote_state.platform
  values = {
    outputs = {
      storage_class_name        = "gp3"
      secrets_name_prefix       = "stroom-proxy/stroom-test/"
      external_secrets_role_arn = "arn:aws:iam::123456789012:role/stroom-test-eso-abc"
      stroom_enabled            = true
      internal_ca = {
        cluster_issuer  = "stroom-internal-ca"
        configmap_name  = "stroom-internal-ca"
        configmap_key   = "ca.crt"
        namespace_label = { key = "stroom.gchq.github.io/internal-ca", value = "true" }
      }
    }
  }
}

override_data {
  target = data.terraform_remote_state.proxy[0]
  values = {
    outputs = {
      namespace               = "stroom-proxy"
      data_bucket             = "stroom-test-data"
      data_events_queue_url   = "https://sqs.eu-west-2.amazonaws.com/123456789012/stroom-test-data-events"
      data_events_queue_arn   = "arn:aws:sqs:eu-west-2:123456789012:stroom-test-data-events"
      data_events_dlq_url     = "https://sqs.eu-west-2.amazonaws.com/123456789012/stroom-test-data-events-dlq"
      data_events_dlq_arn     = "arn:aws:sqs:eu-west-2:123456789012:stroom-test-data-events-dlq"
      data_bucket_kms_key_arn = "arn:aws:kms:eu-west-2:123456789012:key/abc"
      data_retention_days     = 90
      data_expire_after_days  = 91
    }
  }
}

variables {
  infra_state    = { bucket = "state", key = "stroom/test/10-infra.tfstate", region = "eu-west-2" }
  platform_state = { bucket = "state", key = "stroom/test/20-platform.tfstate", region = "eu-west-2" }
  proxy_state    = { bucket = "state", key = "stroom/test/30-stroom-proxy.tfstate", region = "eu-west-2" }

  node_name_prefix = "stroom-test"
  stroom_image     = { tag = "v7.14.0" }
  node_sets = {
    proc = { count = 2, role = "Processing", cpu = 30, memory_gib = 240, heap_gib = 64, data_volume_gb = 1000 }
    ui   = { count = 1, role = "Frontend", cpu = 14, memory_gib = 120, heap_gib = 64, data_volume_gb = 200 }
  }
  idp = {
    tenant_id          = "00000000-0000-0000-0000-000000000000"
    client_id          = "11111111-1111-1111-1111-111111111111"
    client_secret_name = "stroom-oidc-client-secret"
    first_admin        = { subject = "22222222-2222-2222-2222-222222222222", display_name = "First Admin" }
  }
  raw_data_retention_days = 60
  hostname                = "stroom.example.internal"
  allowed_ingress_cidrs   = ["10.0.0.0/8"]
  private_ca_arn          = "arn:aws:acm-pca:eu-west-2:123456789012:certificate-authority/abc"
}

run "with_the_proxy_plan" {
  command = plan

  assert {
    condition     = output.proxy_downstream.hostname == "stroom-test-ui-http.stroom.svc.cluster.local" && output.proxy_downstream.port == 8443
    error_message = "Expected the proxy's downstream to be the Frontend Service on 8443."
  }

  assert {
    condition     = output.proxy_downstream.api_key_secret_name == "stroom-proxy-api-key" && output.proxy_downstream.ca_bundle_configmap == "stroom-internal-ca"
    error_message = "Expected the proxy's API key secret and the in-cluster CA."
  }

  assert {
    condition     = output.node_names == { proc = ["stroom-test-proc-0", "stroom-test-proc-1"], ui = ["stroom-test-ui-0"] }
    error_message = "Expected node names <prefix>-<node set>-<n>."
  }

  assert {
    condition     = output.redirect_uri == "https://stroom.example.internal/api/auth/flow/v1/signin-oidc"
    error_message = "Expected the redirect URI to register."
  }

  assert {
    condition     = output.database.app_user_secret_name == "stroom-proxy/stroom-test/db-stroomuser"
    error_message = "Expected the Stroom user's password under the External Secrets prefix."
  }
}

run "stroom_only_needs_a_bucket" {
  command = plan

  variables {
    proxy_state = null
  }

  expect_failures = [terraform_data.stack_checks]
}

run "stroom_only_plan" {
  command = plan

  variables {
    proxy_state = null
    ingest = {
      bucket            = "other-data"
      queue_url         = "https://sqs.eu-west-2.amazonaws.com/210987654321/other-events"
      queue_arn         = "arn:aws:sqs:eu-west-2:210987654321:other-events"
      dlq_url           = "https://sqs.eu-west-2.amazonaws.com/210987654321/other-events-dlq"
      dlq_arn           = "arn:aws:sqs:eu-west-2:210987654321:other-events-dlq"
      expire_after_days = null
    }
  }

  assert {
    condition     = output.proxy_downstream == null
    error_message = "Expected no proxy wiring in a Stroom-only cluster."
  }
}

run "rejects_a_cluster_without_stroom_nodes" {
  command = plan

  override_data {
    target = data.terraform_remote_state.platform
    values = {
      outputs = {
        storage_class_name        = "gp3"
        secrets_name_prefix       = "stroom-proxy/stroom-test/"
        external_secrets_role_arn = "arn:aws:iam::123456789012:role/stroom-test-eso-abc"
        stroom_enabled            = false
        internal_ca = {
          cluster_issuer  = "stroom-internal-ca"
          configmap_name  = "stroom-internal-ca"
          configmap_key   = "ca.crt"
          namespace_label = { key = "stroom.gchq.github.io/internal-ca", value = "true" }
        }
      }
    }
  }

  expect_failures = [terraform_data.stack_checks]
}

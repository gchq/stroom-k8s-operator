# Plan-only test of the stack's wiring (remote state to module), with mocked
# providers: no credentials or cluster needed.
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
}

mock_provider "helm" {}
mock_provider "kubernetes" {}
mock_provider "external" {}
mock_provider "time" {}

override_data {
  target = data.terraform_remote_state.infra
  values = {
    outputs = {
      aws_region                         = "eu-west-2"
      name                               = "stroom-proxy-test"
      cluster_name                       = "stroom-proxy-test"
      cluster_endpoint                   = "https://example.eks.amazonaws.com"
      cluster_certificate_authority_data = "Y2VydA=="
      vpc_id                             = "vpc-0123456789abcdef0"
      vpc_cidr                           = "10.40.0.0/16"
      lb_subnet_ids                      = ["subnet-lb-a", "subnet-lb-b", "subnet-lb-c"]
      lb_subnet_cidrs                    = ["10.40.208.0/26", "10.40.208.64/26", "10.40.208.128/26"]
      public_subnet_ids                  = ["subnet-pub-a", "subnet-pub-b", "subnet-pub-c"]
      node_security_group_id             = "sg-0123456789abcdef0"
      proxy_node_colours = {
        blue = {
          node_label         = { key = "stroom-proxy/colour", value = "blue" }
          node_count         = 3
          nodes_per_az       = 1
          instance_types     = ["m6i.xlarge"]
          kubernetes_version = "1.37"
          node_groups        = ["proxy-blue-az1", "proxy-blue-az2", "proxy-blue-az3"]
        }
      }
    }
  }
}

override_data {
  target = data.terraform_remote_state.platform
  values = {
    outputs = {
      secrets_name_prefix = "stroom-proxy/stroom-proxy-test/"
      storage_class_name  = "gp3"
    }
  }
}

variables {
  infra_state    = { bucket = "state", key = "test/10-infra.tfstate", region = "eu-west-2" }
  platform_state = { bucket = "state", key = "test/20-platform.tfstate", region = "eu-west-2" }

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

run "stack_plan" {
  command = plan

  assert {
    condition     = output.endpoints["plain"].datafeed_url == "https://proxy.example.internal/datafeed" && output.endpoints["mtls"].datafeed_url == "https://mtls.proxy.example.internal/datafeed"
    error_message = "Expected the plain and mTLS datafeed URLs."
  }

  assert {
    condition     = output.active_colour == "blue" && output.namespace == "stroom-proxy"
    error_message = "Unexpected active colour or namespace."
  }
}

run "client_ca_bundle_from_file" {
  command = plan

  variables {
    client_ca_bundle_pem_file = "tests/fixtures/client-ca.pem"
    auth = {
      openid = {
        issuer            = "https://login.example.com/realms/stroom"
        allowed_audiences = ["stroom-proxy"]
        client_id         = "stroom-proxy"
      }
    }
  }

  assert {
    condition     = module.stroom_proxy.client_ca_bundle_sha256 == filesha256("tests/fixtures/client-ca.pem")
    error_message = "The CA bundle should be read from client_ca_bundle_pem_file."
  }
}

run "imported_certificate_from_files" {
  command = plan

  variables {
    tls_certificate_source = "acm_imported"
    imported_certificate_files = {
      certificate = "tests/fixtures/client-ca.pem"
      private_key = "tests/fixtures/placeholder-key.txt"
    }
  }

  assert {
    condition     = module.stroom_proxy.imported_certificate_sha256 == filesha256("tests/fixtures/client-ca.pem")
    error_message = "The server certificate should be read from imported_certificate_files."
  }
}

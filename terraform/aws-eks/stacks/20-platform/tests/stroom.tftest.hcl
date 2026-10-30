# What 20-platform installs for Stroom, which only a cluster with Stroom node
# sets gets. Plan-only tests against mocked providers.
#
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition = "aws"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
    }
  }
}

mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  infra_state = {
    bucket = "state-bucket"
    key    = "stroom/test/10-infra.tfstate"
    region = "eu-west-2"
  }
}

# --- the stack: Stroom's components follow 10-infra's Stroom node sets ---

run "proxy_only_installs_nothing_for_stroom" {
  command = plan

  # A 10-infra state from before stroom_node_sets existed
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
        system_node_label                  = { key = "workload", value = "system" }
      }
    }
  }

  assert {
    condition     = output.stroom_enabled == false && output.internal_ca == null && output.stroom_operator_namespace == null
    error_message = "Expected none of Stroom's components in a proxy-only cluster."
  }
}

run "stroom_cluster_plan" {
  command = plan

  variables {
    stroom_operator = {
      image_repository = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/stroom-k8s-operator"
      image_tag        = "stroom-eks-f3b5277"
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
        system_node_label                  = { key = "workload", value = "system" }
        stroom_node_sets = {
          proc = { node_count = 2 }
        }
      }
    }
  }

  assert {
    condition     = output.stroom_enabled == true
    error_message = "Expected Stroom's components when the cluster has Stroom node sets."
  }

  assert {
    condition     = output.internal_ca.cluster_issuer == "stroom-internal-ca" && output.internal_ca.configmap_name == "stroom-internal-ca" && output.internal_ca.configmap_key == "ca.crt"
    error_message = "Expected the in-cluster CA's issuer and ConfigMap in the outputs."
  }

  assert {
    condition     = output.stroom_operator_namespace == "stroom-operator"
    error_message = "Expected the operator's namespace in the outputs."
  }
}

# --- the platform module on its own ---

run "module_without_stroom" {
  command = plan

  module {
    source = "../../modules/platform"
  }

  variables {
    cluster_name        = "stroom-test"
    aws_region          = "eu-west-2"
    vpc_id              = "vpc-0123456789abcdef0"
    system_node_label   = { key = "workload", value = "system" }
    secrets_name_prefix = "stroom/test/"
  }

  assert {
    condition = (
      length(helm_release.cert_manager) == 0 &&
      length(helm_release.trust_manager) == 0 &&
      length(helm_release.internal_ca) == 0 &&
      length(helm_release.metrics_server) == 0 &&
      length(helm_release.stroom_operator_crds) == 0 &&
      length(helm_release.stroom_operator) == 0
    )
    error_message = "Expected no Stroom components by default."
  }
}

run "module_with_stroom" {
  command = plan

  module {
    source = "../../modules/platform"
  }

  variables {
    cluster_name        = "stroom-test"
    aws_region          = "eu-west-2"
    vpc_id              = "vpc-0123456789abcdef0"
    system_node_label   = { key = "workload", value = "system" }
    secrets_name_prefix = "stroom/test/"
    stroom_enabled      = true
    stroom_operator = {
      image_repository = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/stroom-k8s-operator"
      image_tag        = "stroom-eks-f3b5277"
    }
    internal_ca_additional_trusted_certificates = "-----BEGIN CERTIFICATE-----\nMIIBold\n-----END CERTIFICATE-----\n"
  }

  assert {
    condition = (
      yamldecode(helm_release.cert_manager[0].values[0]).webhook.nodeSelector.workload == "system" &&
      yamldecode(helm_release.cert_manager[0].values[0]).cainjector.nodeSelector.workload == "system" &&
      yamldecode(helm_release.cert_manager[0].values[0]).startupapicheck.nodeSelector.workload == "system"
    )
    error_message = "Expected cert-manager's webhook, cainjector and startupapicheck on the system nodes."
  }

  assert {
    condition     = yamldecode(helm_release.cert_manager[0].values[0]).global.rbac.aggregateClusterRoles == false
    error_message = "cert-manager must not aggregate Certificate rights into the default edit and admin roles."
  }

  assert {
    condition     = length(time_sleep.trust_manager_webhook) == 1 && time_sleep.trust_manager_webhook[0].create_duration == "30s"
    error_message = "Expected a wait for trust-manager's webhook before the CA's Bundle is created."
  }

  assert {
    condition = (
      yamldecode(helm_release.internal_ca[0].values[0]).chartChecksum == local.local_chart_checksums["internal_ca"] &&
      yamldecode(helm_release.stroom_operator[0].values[0]).chartChecksum == local.local_chart_checksums["stroom_operator"] &&
      yamldecode(helm_release.stroom_operator_crds[0].values[0]).chartChecksum == local.local_chart_checksums["stroom_operator_crds"] &&
      length(distinct(values(local.local_chart_checksums))) == 3
    )
    error_message = "Expected each local chart's checksum in its release's values, so a change to the chart upgrades the release."
  }

  assert {
    condition     = startswith(yamldecode(helm_release.internal_ca[0].values[0]).additionalTrustedCertificates, "-----BEGIN CERTIFICATE-----")
    error_message = "Expected the extra trusted CA certificates passed to the CA chart."
  }

  assert {
    condition = (
      length(helm_release.cert_manager) == 1 &&
      length(helm_release.trust_manager) == 1 &&
      length(helm_release.internal_ca) == 1 &&
      length(helm_release.metrics_server) == 1 &&
      length(helm_release.stroom_operator_crds) == 1 &&
      length(helm_release.stroom_operator) == 1
    )
    error_message = "Expected all of Stroom's components."
  }

  assert {
    condition     = endswith(helm_release.stroom_operator[0].chart, "/charts/stroom-operator") && helm_release.stroom_operator[0].repository == null
    error_message = "Expected the operator from this repository's charts by default."
  }

  assert {
    condition     = fileexists("${helm_release.stroom_operator[0].chart}/Chart.yaml") && fileexists("${helm_release.stroom_operator_crds[0].chart}/Chart.yaml")
    error_message = "Expected the local operator chart paths to point at the charts."
  }

  assert {
    condition     = fileexists("${helm_release.internal_ca[0].chart}/Chart.yaml")
    error_message = "Expected the in-cluster CA chart."
  }

  assert {
    condition = alltrue([
      for r in [helm_release.cert_manager[0], helm_release.trust_manager[0], helm_release.metrics_server[0], helm_release.stroom_operator[0]] :
      yamldecode(r.values[0]).nodeSelector.workload == "system"
    ])
    error_message = "Expected Stroom's cluster components on the system nodes."
  }

  assert {
    condition     = yamldecode(helm_release.internal_ca[0].values[0]).namespaceLabel.key == "stroom.gchq.github.io/internal-ca"
    error_message = "Expected the CA bundle to go to namespaces with the internal-ca label."
  }
}

run "module_operator_from_a_repository_and_registry" {
  command = plan

  module {
    source = "../../modules/platform"
  }

  variables {
    cluster_name        = "stroom-test"
    aws_region          = "eu-west-2"
    vpc_id              = "vpc-0123456789abcdef0"
    system_node_label   = { key = "workload", value = "system" }
    secrets_name_prefix = "stroom/test/"
    stroom_enabled      = true
    stroom_operator = {
      chart_repository = "oci://ghcr.io/gchq/helm-charts"
      chart_version    = "2.1.0"
      image_repository = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/stroom-k8s-operator"
      image_tag        = "stroom-eks-f3b5277"
    }
  }

  assert {
    condition = (
      helm_release.stroom_operator[0].chart == "stroom-operator" &&
      helm_release.stroom_operator[0].repository == "oci://ghcr.io/gchq/helm-charts" &&
      helm_release.stroom_operator_crds[0].chart == "stroom-operator-crds" &&
      helm_release.stroom_operator_crds[0].version == "2.1.0"
    )
    error_message = "Expected the operator charts from the given repository and version."
  }

  assert {
    condition = (
      yamldecode(helm_release.stroom_operator[0].values[0]).registry == "123456789012.dkr.ecr.eu-west-2.amazonaws.com/stroom-k8s-operator" &&
      yamldecode(helm_release.stroom_operator[0].values[0]).image.tag == "stroom-eks-f3b5277"
    )
    error_message = "Expected the given operator image."
  }

  assert {
    condition     = !can(yamldecode(helm_release.stroom_operator[0].values[0]).chartChecksum) && length(helm_release.stroom_operator_crds[0].values) == 0
    error_message = "A chart from a repository is upgraded by its version; no checksum needed."
  }
}

run "module_rejects_local_charts_without_an_image" {
  command = plan

  module {
    source = "../../modules/platform"
  }

  variables {
    cluster_name        = "stroom-test"
    aws_region          = "eu-west-2"
    vpc_id              = "vpc-0123456789abcdef0"
    system_node_label   = { key = "workload", value = "system" }
    secrets_name_prefix = "stroom/test/"
    stroom_enabled      = true
    stroom_operator     = { image_tag = "stroom-eks-f3b5277" }
  }

  expect_failures = [var.stroom_operator]
}

run "module_rejects_bad_extra_ca" {
  command = plan

  module {
    source = "../../modules/platform"
  }

  variables {
    cluster_name        = "stroom-test"
    aws_region          = "eu-west-2"
    vpc_id              = "vpc-0123456789abcdef0"
    system_node_label   = { key = "workload", value = "system" }
    secrets_name_prefix = "stroom/test/"
    stroom_enabled      = true
    stroom_operator = {
      image_repository = "123456789012.dkr.ecr.eu-west-2.amazonaws.com/stroom-k8s-operator"
      image_tag        = "stroom-eks-f3b5277"
    }
    internal_ca_additional_trusted_certificates = "not a certificate"
  }

  expect_failures = [var.internal_ca_additional_trusted_certificates]
}

# Plan-only tests against mocked providers: no credentials or cluster needed.
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

# What 10-infra would output.
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
      system_node_label                  = { key = "workload", value = "system" }
    }
  }
}

variables {
  infra_state = {
    bucket = "state-bucket"
    key    = "stroom-proxy/test/10-infra.tfstate"
    region = "eu-west-2"
  }
}

run "stack_defaults_plan" {
  command = plan

  assert {
    condition     = output.secrets_name_prefix == "stroom-proxy/stroom-proxy-test/"
    error_message = "Expected the secrets prefix to default to stroom-proxy/<name>/."
  }

  assert {
    condition     = output.storage_class_name == "gp3"
    error_message = "Expected a gp3 StorageClass."
  }
}

run "module_values" {
  command = plan

  module {
    source = "../../modules/platform"
  }

  variables {
    cluster_name        = "stroom-proxy-test"
    aws_region          = "eu-west-2"
    vpc_id              = "vpc-0123456789abcdef0"
    system_node_label   = { key = "workload", value = "system" }
    secrets_name_prefix = "stroom-proxy/test/"
  }

  assert {
    condition     = yamldecode(helm_release.lb_controller.values[0]).vpcId == "vpc-0123456789abcdef0" && yamldecode(helm_release.lb_controller.values[0]).region == "eu-west-2"
    error_message = "The load balancer controller must be given its VPC and region (pods can't read instance metadata)."
  }

  assert {
    condition     = yamldecode(helm_release.lb_controller.values[0]).nodeSelector.workload == "system"
    error_message = "The load balancer controller must run on the system nodes."
  }

  assert {
    condition     = yamldecode(helm_release.lb_controller.values[0]).enableServiceMutatorWebhook == false && yamldecode(helm_release.lb_controller.values[0]).createIngressClassResource == false
    error_message = "The load balancer controller's Service mutator and ingress class should be off."
  }

  assert {
    condition     = yamldecode(helm_release.lb_controller.values[0]).podMutatorWebhookConfig.failurePolicy == "Fail"
    error_message = "Proxy pods must not be created without their readiness gates."
  }

  assert {
    condition     = yamldecode(helm_release.external_secrets.values[0]).global.nodeSelector.workload == "system"
    error_message = "External Secrets must run on the system nodes."
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.parameters["iops"] == "3000" && kubernetes_storage_class_v1.gp3.parameters["throughput"] == "250" && kubernetes_storage_class_v1.gp3.parameters["encrypted"] == "true"
    error_message = "Unexpected gp3 StorageClass parameters."
  }

  assert {
    condition     = kubernetes_storage_class_v1.gp3.volume_binding_mode == "WaitForFirstConsumer"
    error_message = "gp3 volumes must bind when the pod is scheduled, so they are created in the pod's AZ."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.container_insights) == 4 && alltrue([for g in aws_cloudwatch_log_group.container_insights : g.retention_in_days == 90])
    error_message = "Expected four Container Insights log groups with 90-day retention."
  }

  assert {
    condition     = jsondecode(aws_eks_addon.cloudwatch.configuration_values).manager.applicationSignals.autoMonitor.monitorAllServices == false
    error_message = "Application Signals auto-monitor must be off: its injected agent breaks the proxy's restricted Pod Security level."
  }

  assert {
    condition     = aws_eks_pod_identity_association.lb_controller.service_account == "aws-load-balancer-controller" && aws_eks_pod_identity_association.external_secrets.namespace == "external-secrets"
    error_message = "Pod Identity associations must match the controllers' service accounts."
  }
}

run "rejects_throughput_above_iops_ratio" {
  command = plan

  module {
    source = "../../modules/platform"
  }

  variables {
    cluster_name        = "stroom-proxy-test"
    aws_region          = "eu-west-2"
    vpc_id              = "vpc-0123456789abcdef0"
    system_node_label   = { key = "workload", value = "system" }
    secrets_name_prefix = "stroom-proxy/test/"
    gp3_iops            = 3000
    gp3_throughput      = 1000
  }

  expect_failures = [var.gp3_throughput]
}

run "rejects_bad_retention" {
  command = plan

  module {
    source = "../../modules/platform"
  }

  variables {
    cluster_name        = "stroom-proxy-test"
    aws_region          = "eu-west-2"
    vpc_id              = "vpc-0123456789abcdef0"
    system_node_label   = { key = "workload", value = "system" }
    secrets_name_prefix = "stroom-proxy/test/"
    log_retention_days  = 45
  }

  expect_failures = [var.log_retention_days]
}

run "rejects_secrets_prefix_without_slash" {
  command = plan

  module {
    source = "../../modules/platform"
  }

  variables {
    cluster_name        = "stroom-proxy-test"
    aws_region          = "eu-west-2"
    vpc_id              = "vpc-0123456789abcdef0"
    system_node_label   = { key = "workload", value = "system" }
    secrets_name_prefix = "stroom-proxy"
  }

  expect_failures = [var.secrets_name_prefix]
}

run "rejects_old_cloudwatch_addon" {
  command = plan

  module {
    source = "../../modules/platform"
  }

  variables {
    cluster_name             = "stroom-proxy-test"
    aws_region               = "eu-west-2"
    vpc_id                   = "vpc-0123456789abcdef0"
    system_node_label        = { key = "workload", value = "system" }
    secrets_name_prefix      = "stroom-proxy/test/"
    cloudwatch_addon_version = "v1.6.0-eksbuild.1"
  }

  expect_failures = [var.cloudwatch_addon_version]
}

run "rejects_v0_cloudwatch_addon" {
  command = plan

  module {
    source = "../../modules/platform"
  }

  variables {
    cluster_name             = "stroom-proxy-test"
    aws_region               = "eu-west-2"
    vpc_id                   = "vpc-0123456789abcdef0"
    system_node_label        = { key = "workload", value = "system" }
    secrets_name_prefix      = "stroom-proxy/test/"
    cloudwatch_addon_version = "v0.9.0-eksbuild.1"
  }

  expect_failures = [var.cloudwatch_addon_version]
}

run "allows_current_cloudwatch_addon" {
  command = plan

  module {
    source = "../../modules/platform"
  }

  variables {
    cluster_name             = "stroom-proxy-test"
    aws_region               = "eu-west-2"
    vpc_id                   = "vpc-0123456789abcdef0"
    system_node_label        = { key = "workload", value = "system" }
    secrets_name_prefix      = "stroom-proxy/test/"
    cloudwatch_addon_version = "v4.1.0-eksbuild.1"
  }
}

run "allows_first_tolerating_cloudwatch_addon" {
  command = plan

  module {
    source = "../../modules/platform"
  }

  variables {
    cluster_name             = "stroom-proxy-test"
    aws_region               = "eu-west-2"
    vpc_id                   = "vpc-0123456789abcdef0"
    system_node_label        = { key = "workload", value = "system" }
    secrets_name_prefix      = "stroom-proxy/test/"
    cloudwatch_addon_version = "v1.7.0-eksbuild.1"
  }
}

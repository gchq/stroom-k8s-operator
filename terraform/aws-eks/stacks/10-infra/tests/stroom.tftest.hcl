# Stroom node groups and the deployment shapes (proxy only, Stroom only, both).
# Plan-only tests against a mocked AWS provider: no credentials needed.
#
#   terraform init -backend=false && terraform test

mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-west-2a", "eu-west-2b", "eu-west-2c"]
    }
  }

  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:role/terraform"
    }
  }

  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::123456789012:role/terraform"
    }
  }
}

variables {
  aws_region = "eu-west-2"
  name       = "stroom-test"
}

run "proxy_only_has_no_stroom_nodes" {
  command = plan

  assert {
    condition     = output.stroom_node_sets == {}
    error_message = "Expected no Stroom node sets by default."
  }

  assert {
    condition     = length(output.proxy_node_colours) == 1
    error_message = "Expected the default proxy colour."
  }
}

run "stroom_only_plan" {
  command = plan

  variables {
    proxy_node_colours = {}
    stroom_node_sets = {
      proc = { instance_types = ["r6id.8xlarge"], node_count = 2, kubernetes_version = "1.37" }
      ui   = { instance_types = ["r6id.4xlarge"], node_count = 1, kubernetes_version = "1.37" }
    }
  }

  assert {
    condition     = output.proxy_node_colours == {}
    error_message = "Expected no proxy nodes."
  }

  assert {
    condition     = output.stroom_node_sets["proc"].node_groups == tolist(["stroom-proc-az1", "stroom-proc-az2"])
    error_message = "Expected 2 proc nodes in the first two AZs, one node group each."
  }

  assert {
    condition     = output.stroom_node_sets["ui"].node_groups == tolist(["stroom-ui-az1"])
    error_message = "Expected 1 ui node in the first AZ."
  }

  assert {
    condition     = output.stroom_node_sets["proc"].node_label.key == "stroom/node-set" && output.stroom_node_sets["proc"].node_label.value == "proc"
    error_message = "Expected proc nodes to be labelled stroom/node-set=proc."
  }

  assert {
    condition     = output.stroom_node_taint.key == "workload" && output.stroom_node_taint.value == "stroom" && output.stroom_node_taint.effect == "NoSchedule"
    error_message = "Expected Stroom nodes to be tainted workload=stroom:NoSchedule."
  }
}

run "both_plan" {
  command = plan

  variables {
    stroom_node_sets = {
      proc = { instance_types = ["r6id.8xlarge"], node_count = 4, kubernetes_version = "1.37" }
    }
  }

  assert {
    condition     = length(output.proxy_node_colours["blue"].node_groups) == 3 && length(output.stroom_node_sets["proc"].node_groups) == 3
    error_message = "Expected proxy and Stroom node groups side by side."
  }
}

run "rejects_neither" {
  command = plan

  variables {
    proxy_node_colours = {}
  }

  expect_failures = [var.proxy_node_colours]
}

# --- the eks module on its own: node spread, add-ons and validations ---

run "spreads_nodes_over_azs" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {}
    stroom_node_sets = {
      proc = { instance_types = ["r6id.8xlarge"], node_count = 5, kubernetes_version = "1.37" }
    }
  }

  assert {
    condition = (
      local.stroom_node_groups["stroom-proc-az1"].node_count == 2 &&
      local.stroom_node_groups["stroom-proc-az2"].node_count == 2 &&
      local.stroom_node_groups["stroom-proc-az3"].node_count == 1
    )
    error_message = "Expected 5 nodes spread 2, 2, 1 over three AZs."
  }

  assert {
    condition     = local.stroom_node_groups["stroom-proc-az1"].subnet_id == "subnet-a" && local.stroom_node_groups["stroom-proc-az3"].subnet_id == "subnet-c"
    error_message = "Expected each node group in its own AZ's subnet."
  }

  assert {
    condition     = length(aws_iam_role.efs_csi) == 1
    error_message = "Expected the EFS CSI driver's role with Stroom node sets."
  }
}

run "no_efs_without_stroom" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {
      blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37" }
    }
  }

  assert {
    condition     = length(aws_iam_role.efs_csi) == 0 && local.stroom_node_groups == {}
    error_message = "Expected nothing for Stroom in a proxy-only cluster."
  }
}

run "rejects_no_instance_store" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {}
    stroom_node_sets = {
      proc = { instance_types = ["r6i.8xlarge"], node_count = 2, kubernetes_version = "1.37" }
    }
  }

  expect_failures = [var.stroom_node_sets]
}

run "allows_instance_store_families" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {}
    stroom_node_sets = {
      proc = { instance_types = ["r6id.8xlarge", "m6id.8xlarge", "c6id.8xlarge", "m5dn.8xlarge", "x2idn.16xlarge", "i4i.8xlarge", "i3en.6xlarge"], node_count = 2, kubernetes_version = "1.37" }
    }
  }
}

run "rejects_graviton_stroom_nodes" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {}
    stroom_node_sets = {
      proc = { instance_types = ["r7gd.8xlarge"], node_count = 2, kubernetes_version = "1.37" }
    }
  }

  expect_failures = [var.stroom_node_sets]
}

run "rejects_bad_node_set_name" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {}
    stroom_node_sets = {
      "Processing-Nodes" = { instance_types = ["r6id.8xlarge"], node_count = 2, kubernetes_version = "1.37" }
    }
  }

  expect_failures = [var.stroom_node_sets]
}

run "rejects_zero_stroom_nodes" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {}
    stroom_node_sets = {
      proc = { instance_types = ["r6id.8xlarge"], node_count = 0, kubernetes_version = "1.37" }
    }
  }

  expect_failures = [var.stroom_node_sets]
}

run "rejects_stroom_nodes_newer_than_cluster" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {}
    stroom_node_sets = {
      proc = { instance_types = ["r6id.8xlarge"], node_count = 2, kubernetes_version = "1.38" }
    }
  }

  expect_failures = [var.stroom_node_sets]
}

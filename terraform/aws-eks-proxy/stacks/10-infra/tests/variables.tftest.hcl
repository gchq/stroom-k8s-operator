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

  # Every mocked subnet is in the same AZ unless a run overrides it.
  mock_data "aws_subnet" {
    defaults = {
      cidr_block        = "10.0.0.0/26"
      availability_zone = "eu-west-2a"
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
  name       = "stroom-proxy-test"
}

run "defaults_plan" {
  command = plan

  assert {
    condition     = length(module.network.private_subnet_ids) == 3
    error_message = "Expected three private subnets."
  }

  assert {
    condition     = output.proxy_node_colours["blue"].node_groups == tolist(["proxy-blue-az1", "proxy-blue-az2", "proxy-blue-az3"])
    error_message = "Expected one blue proxy node group per AZ."
  }

  assert {
    condition     = output.proxy_node_colours["blue"].node_label.key == "stroom-proxy/colour" && output.proxy_node_colours["blue"].node_label.value == "blue"
    error_message = "Expected blue nodes to be labelled stroom-proxy/colour=blue."
  }

  assert {
    condition     = output.lb_subnet_cidrs == tolist(["10.40.208.0/26", "10.40.208.64/26", "10.40.208.128/26"])
    error_message = "Expected a /26 lb subnet per AZ, after the public subnets."
  }
}

run "small_vpc_plan" {
  command = plan

  variables {
    vpc_cidr = "10.50.0.0/20"
  }

  assert {
    condition     = output.lb_subnet_cidrs == tolist(["10.50.13.0/26", "10.50.13.64/26", "10.50.13.128/26"])
    error_message = "Expected /26 lb subnets after the public subnets in a /20 VPC."
  }
}

run "blue_green_plan" {
  command = plan

  variables {
    proxy_node_colours = {
      blue  = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.36", ami_release_version = "1.36.5-20260901" }
      green = { instance_types = ["m7i.xlarge"], kubernetes_version = "1.37", nodes_per_az = 2 }
    }
  }

  assert {
    condition     = length(output.proxy_node_colours["green"].node_groups) == 3 && output.proxy_node_colours["green"].node_count == 6
    error_message = "Expected three green node groups with six nodes in total."
  }

  assert {
    condition     = output.proxy_node_colours["blue"].kubernetes_version == "1.36"
    error_message = "Expected blue nodes to keep their own Kubernetes version."
  }
}

run "existing_vpc_plan" {
  command = plan

  variables {
    existing_vpc_id             = "vpc-0123456789abcdef0"
    existing_private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    existing_lb_subnet_ids      = ["subnet-d", "subnet-e", "subnet-f"]
  }

  override_data {
    target = module.network.data.aws_subnet.existing_private[0]
    values = { availability_zone = "eu-west-2a", cidr_block = "10.0.0.0/26" }
  }

  override_data {
    target = module.network.data.aws_subnet.existing_private[1]
    values = { availability_zone = "eu-west-2b", cidr_block = "10.0.1.0/26" }
  }

  override_data {
    target = module.network.data.aws_subnet.existing_private[2]
    values = { availability_zone = "eu-west-2c", cidr_block = "10.0.2.0/26" }
  }

  override_data {
    target = module.network.data.aws_subnet.existing_lb[0]
    values = { availability_zone = "eu-west-2a", cidr_block = "10.0.0.0/26" }
  }

  override_data {
    target = module.network.data.aws_subnet.existing_lb[1]
    values = { availability_zone = "eu-west-2b", cidr_block = "10.0.1.0/26" }
  }

  override_data {
    target = module.network.data.aws_subnet.existing_lb[2]
    values = { availability_zone = "eu-west-2c", cidr_block = "10.0.2.0/26" }
  }

  assert {
    condition     = module.network.vpc_id == "vpc-0123456789abcdef0"
    error_message = "Expected the existing VPC to be used."
  }

  assert {
    condition     = length(output.lb_subnet_cidrs) == 3
    error_message = "Expected the existing lb subnets' CIDRs to be looked up."
  }
}

run "rejects_existing_vpc_without_lb_subnets" {
  command = plan

  module {
    source = "../../modules/network"
  }

  variables {
    existing_vpc_id             = "vpc-0123456789abcdef0"
    existing_private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
  }

  override_data {
    target = data.aws_subnet.existing_private[0]
    values = { availability_zone = "eu-west-2a" }
  }

  override_data {
    target = data.aws_subnet.existing_private[1]
    values = { availability_zone = "eu-west-2b" }
  }

  override_data {
    target = data.aws_subnet.existing_private[2]
    values = { availability_zone = "eu-west-2c" }
  }

  expect_failures = [var.existing_lb_subnet_ids]
}

run "rejects_existing_subnets_in_one_az" {
  command = plan

  module {
    source = "../../modules/network"
  }

  variables {
    existing_vpc_id             = "vpc-0123456789abcdef0"
    existing_private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    existing_lb_subnet_ids      = ["subnet-d", "subnet-e", "subnet-f"]
  }

  expect_failures = [output.private_subnet_ids, output.lb_subnet_ids]
}

run "rejects_small_lb_subnets" {
  command = plan

  module {
    source = "../../modules/network"
  }

  variables {
    existing_vpc_id             = "vpc-0123456789abcdef0"
    existing_private_subnet_ids = ["subnet-a", "subnet-b"]
    existing_lb_subnet_ids      = ["subnet-d", "subnet-e"]
  }

  override_data {
    target = data.aws_subnet.existing_private[0]
    values = { availability_zone = "eu-west-2a", cidr_block = "10.0.0.0/24" }
  }

  override_data {
    target = data.aws_subnet.existing_private[1]
    values = { availability_zone = "eu-west-2b", cidr_block = "10.0.1.0/24" }
  }

  override_data {
    target = data.aws_subnet.existing_lb[0]
    values = { availability_zone = "eu-west-2a", cidr_block = "10.0.0.0/28" }
  }

  override_data {
    target = data.aws_subnet.existing_lb[1]
    values = { availability_zone = "eu-west-2b", cidr_block = "10.0.1.0/28" }
  }

  expect_failures = [output.lb_subnet_ids]
}

run "rejects_long_name" {
  command = plan

  variables {
    name = "stroom-proxy-name-much-too-long"
  }

  expect_failures = [var.name]
}

run "rejects_duplicate_admins" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name         = "stroom-proxy-test"
    kubernetes_version   = "1.37"
    vpc_id               = "vpc-0123456789abcdef0"
    private_subnet_ids   = ["subnet-a", "subnet-b", "subnet-c"]
    admin_principal_arns = ["arn:aws:iam::123456789012:role/Admin", "arn:aws:iam::123456789012:role/Admin"]
    proxy_node_colours = {
      blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37" }
    }
  }

  expect_failures = [var.admin_principal_arns]
}

run "rejects_graviton" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-proxy-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {
      blue = { instance_types = ["m7g.xlarge"], kubernetes_version = "1.37" }
    }
  }

  expect_failures = [var.proxy_node_colours]
}

run "rejects_graviton_variants" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-proxy-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {
      blue = { instance_types = ["m6i.xlarge", "c7gn.large"], kubernetes_version = "1.37" }
    }
  }

  expect_failures = [var.proxy_node_colours]
}

run "allows_x86_gpu_and_flex" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-proxy-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {
      blue = { instance_types = ["g5.xlarge", "g4dn.xlarge", "c7i-flex.large", "m5dn.large"], kubernetes_version = "1.37" }
    }
  }
}

run "rejects_three_colours" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-proxy-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {
      blue  = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37" }
      green = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37" }
      red   = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37" }
    }
  }

  expect_failures = [var.proxy_node_colours]
}

run "rejects_bad_colour_name" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-proxy-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {
      Blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37" }
    }
  }

  expect_failures = [var.proxy_node_colours]
}

run "rejects_zero_nodes_per_az" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-proxy-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {
      blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37", nodes_per_az = 0 }
    }
  }

  expect_failures = [var.proxy_node_colours]
}

run "rejects_nodes_newer_than_cluster" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-proxy-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {
      blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.38" }
    }
  }

  expect_failures = [var.proxy_node_colours]
}

run "rejects_nodes_too_old" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-proxy-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {
      blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.33" }
    }
  }

  expect_failures = [var.proxy_node_colours]
}

run "allows_nodes_three_versions_old" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-proxy-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {
      blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.34" }
    }
  }
}

run "rejects_ami_for_other_version" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-proxy-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    proxy_node_colours = {
      blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37", ami_release_version = "1.36.5-20260901" }
    }
  }

  expect_failures = [var.proxy_node_colours]
}

run "rejects_open_api_endpoint" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name       = "stroom-proxy-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-a", "subnet-b", "subnet-c"]
    api_allowed_cidrs  = ["0.0.0.0/0"]
    proxy_node_colours = {
      blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37" }
    }
  }

  expect_failures = [var.api_allowed_cidrs]
}

run "rejects_bad_nat_mode" {
  command = plan

  module {
    source = "../../modules/network"
  }

  variables {
    nat_gateway_mode = "none"
  }

  expect_failures = [var.nat_gateway_mode]
}

run "spot_warns" {
  command = plan

  variables {
    proxy_node_colours = {
      blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37", capacity_type = "SPOT" }
    }
  }

  expect_failures = [check.proxy_nodes_on_demand]
}

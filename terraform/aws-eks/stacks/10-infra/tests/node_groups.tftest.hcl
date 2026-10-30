# Node groups: what the Stroom groups are given, per-AZ overrides, system node
# capacity, pinned AZs, and node groups that already exist (sizes changed with
# the AWS CLI, guards against moving, shrinking or removing groups).
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

  mock_data "aws_region" {
    defaults = {
      region = "eu-west-2"
    }
  }

  # No cluster yet, unless a run overrides it.
  mock_data "aws_eks_clusters" {
    defaults = {
      names = []
    }
  }
}

variables {
  aws_region = "eu-west-2"
  name       = "stroom-test"
}

# --- what the Stroom node groups are given ---

run "stroom_node_group_config" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name              = "stroom-test"
    kubernetes_version        = "1.37"
    vpc_id                    = "vpc-0123456789abcdef0"
    private_subnet_ids        = ["subnet-a", "subnet-b", "subnet-c"]
    system_node_instance_type = "t3.large"
    proxy_node_colours        = {}
    stroom_node_sets = {
      proc = { instance_types = ["r6id.8xlarge"], node_count = 2, kubernetes_version = "1.37", ami_release_version = "1.37.4-20261020" }
    }
  }

  assert {
    condition = alltrue([
      for k in ["stroom-proc-az1", "stroom-proc-az2"] :
      local.eks_managed_node_groups[k].use_latest_ami_release_version == false &&
      local.eks_managed_node_groups[k].ami_release_version == "1.37.4-20261020" &&
      local.eks_managed_node_groups[k].kubernetes_version == "1.37"
    ])
    error_message = "Stroom node groups must have a fixed Kubernetes version and AMI, never the latest AMI."
  }

  assert {
    condition = (
      local.eks_managed_node_groups["stroom-proc-az1"].cloudinit_pre_nodeadm[0].content_type == "application/node.eks.aws" &&
      yamldecode(local.eks_managed_node_groups["stroom-proc-az1"].cloudinit_pre_nodeadm[0].content).spec.instance.localStorage.strategy == "RAID0"
    )
    error_message = "Stroom nodes must put kubelet and containerd on a RAID0 array of the instance-store disks (nodeadm localStorage)."
  }

  assert {
    condition = (
      module.eks.eks_managed_node_groups["stroom-proc-az1"].node_group_labels == tomap({ "workload" = "stroom", "stroom/node-set" = "proc" }) &&
      length(module.eks.eks_managed_node_groups["stroom-proc-az1"].node_group_taints) == 1 &&
      one(module.eks.eks_managed_node_groups["stroom-proc-az1"].node_group_taints).key == "workload" &&
      one(module.eks.eks_managed_node_groups["stroom-proc-az1"].node_group_taints).value == "stroom" &&
      one(module.eks.eks_managed_node_groups["stroom-proc-az1"].node_group_taints).effect == "NO_SCHEDULE"
    )
    error_message = "Stroom node groups must be labelled workload=stroom, stroom/node-set=<set> and tainted workload=stroom:NoSchedule."
  }

  assert {
    condition     = local.eks_managed_node_groups["stroom-proc-az1"].subnet_ids == ["subnet-a"] && local.eks_managed_node_groups["stroom-proc-az1"].capacity_type == "ON_DEMAND"
    error_message = "Expected each Stroom node group On-Demand, in its own AZ's subnet."
  }

  assert {
    condition     = local.eks_managed_node_groups["stroom-proc-az1"].min_size == 1 && local.eks_managed_node_groups["stroom-proc-az1"].max_size == 1 && local.eks_managed_node_groups["stroom-proc-az1"].desired_size == 1
    error_message = "A new node group must be created with its configured size."
  }
}

run "az_overrides_change_one_group" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name              = "stroom-test"
    kubernetes_version        = "1.37"
    vpc_id                    = "vpc-0123456789abcdef0"
    private_subnet_ids        = ["subnet-a", "subnet-b", "subnet-c"]
    system_node_instance_type = "t3.large"
    proxy_node_colours        = {}
    stroom_node_sets = {
      proc = {
        instance_types      = ["r6id.8xlarge"]
        node_count          = 3
        kubernetes_version  = "1.36"
        ami_release_version = "1.36.5-20260901"
        az_overrides = {
          az1 = { kubernetes_version = "1.37", ami_release_version = "1.37.4-20261020" }
          az2 = { instance_types = ["r7id.8xlarge"] }
        }
      }
    }
  }

  assert {
    condition = (
      local.eks_managed_node_groups["stroom-proc-az1"].kubernetes_version == "1.37" &&
      local.eks_managed_node_groups["stroom-proc-az1"].ami_release_version == "1.37.4-20261020" &&
      local.eks_managed_node_groups["stroom-proc-az1"].instance_types == tolist(["r6id.8xlarge"])
    )
    error_message = "Expected az1 to take its overridden version and AMI and the set's instance types."
  }

  assert {
    condition = (
      local.eks_managed_node_groups["stroom-proc-az2"].instance_types == tolist(["r7id.8xlarge"]) &&
      local.eks_managed_node_groups["stroom-proc-az2"].ami_release_version == "1.36.5-20260901"
    )
    error_message = "Expected az2 to take its overridden instance types and the set's AMI."
  }

  assert {
    condition = (
      local.eks_managed_node_groups["stroom-proc-az3"].instance_types == tolist(["r6id.8xlarge"]) &&
      local.eks_managed_node_groups["stroom-proc-az3"].kubernetes_version == "1.36" &&
      local.eks_managed_node_groups["stroom-proc-az3"].ami_release_version == "1.36.5-20260901"
    )
    error_message = "Expected az3 to keep the set's values."
  }
}

run "rejects_override_for_missing_az_group" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name              = "stroom-test"
    kubernetes_version        = "1.37"
    vpc_id                    = "vpc-0123456789abcdef0"
    private_subnet_ids        = ["subnet-a", "subnet-b", "subnet-c"]
    system_node_instance_type = "t3.large"
    proxy_node_colours        = {}
    stroom_node_sets = {
      proc = {
        instance_types     = ["r6id.8xlarge"]
        node_count         = 2
        kubernetes_version = "1.37"
        az_overrides       = { az3 = { ami_release_version = "1.37.4-20261020" } }
      }
    }
  }

  expect_failures = [var.stroom_node_sets]
}

run "rejects_override_without_instance_store" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name              = "stroom-test"
    kubernetes_version        = "1.37"
    vpc_id                    = "vpc-0123456789abcdef0"
    private_subnet_ids        = ["subnet-a", "subnet-b", "subnet-c"]
    system_node_instance_type = "t3.large"
    proxy_node_colours        = {}
    stroom_node_sets = {
      proc = {
        instance_types     = ["r6id.8xlarge"]
        node_count         = 2
        kubernetes_version = "1.37"
        az_overrides       = { az1 = { instance_types = ["r6i.8xlarge"] } }
      }
    }
  }

  expect_failures = [var.stroom_node_sets]
}

run "rejects_override_version_without_matching_ami" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name              = "stroom-test"
    kubernetes_version        = "1.37"
    vpc_id                    = "vpc-0123456789abcdef0"
    private_subnet_ids        = ["subnet-a", "subnet-b", "subnet-c"]
    system_node_instance_type = "t3.large"
    proxy_node_colours        = {}
    stroom_node_sets = {
      proc = {
        instance_types      = ["r6id.8xlarge"]
        node_count          = 2
        kubernetes_version  = "1.36"
        ami_release_version = "1.36.5-20260901"
        az_overrides        = { az1 = { kubernetes_version = "1.37" } }
      }
    }
  }

  expect_failures = [var.stroom_node_sets]
}

# --- system node capacity with Stroom ---

run "rejects_small_system_nodes_with_stroom" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name              = "stroom-test"
    kubernetes_version        = "1.37"
    vpc_id                    = "vpc-0123456789abcdef0"
    private_subnet_ids        = ["subnet-a", "subnet-b", "subnet-c"]
    system_node_instance_type = "t3.medium"
    system_node_count         = 3
    proxy_node_colours        = {}
    stroom_node_sets = {
      proc = { instance_types = ["r6id.8xlarge"], node_count = 2, kubernetes_version = "1.37" }
    }
  }

  expect_failures = [var.system_node_count]
}

run "allows_small_system_nodes_without_stroom" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name              = "stroom-test"
    kubernetes_version        = "1.37"
    vpc_id                    = "vpc-0123456789abcdef0"
    private_subnet_ids        = ["subnet-a", "subnet-b", "subnet-c"]
    system_node_instance_type = "t3.medium"
    system_node_count         = 2
    proxy_node_colours = {
      blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37" }
    }
  }
}

run "warns_about_unknown_system_node_type_with_stroom" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name              = "stroom-test"
    kubernetes_version        = "1.37"
    vpc_id                    = "vpc-0123456789abcdef0"
    private_subnet_ids        = ["subnet-a", "subnet-b", "subnet-c"]
    system_node_instance_type = "m8i.large"
    proxy_node_colours        = {}
    stroom_node_sets = {
      proc = { instance_types = ["r6id.8xlarge"], node_count = 2, kubernetes_version = "1.37" }
    }
  }

  expect_failures = [check.system_node_capacity]
}

# --- AZs ---

run "pinned_azs_plan" {
  command = plan

  variables {
    az_count = 3
    azs      = ["eu-west-2c", "eu-west-2a"]
  }

  assert {
    condition     = output.availability_zones == tolist(["eu-west-2c", "eu-west-2a"]) && length(output.private_subnet_ids) == 2
    error_message = "Expected the pinned AZs, in order, to override az_count."
  }

  assert {
    condition     = output.proxy_node_colours["blue"].node_groups == tolist(["proxy-blue-az1", "proxy-blue-az2"])
    error_message = "Expected one proxy node group per pinned AZ."
  }
}

run "default_azs_unchanged" {
  command = plan

  assert {
    condition     = output.availability_zones == tolist(["eu-west-2a", "eu-west-2b", "eu-west-2c"])
    error_message = "Without azs, the first az_count available zones must be used, as before."
  }
}

run "rejects_duplicate_azs" {
  command = plan

  module {
    source = "../../modules/network"
  }

  variables {
    azs = ["eu-west-2a", "eu-west-2a"]
  }

  expect_failures = [var.azs]
}

# --- node groups that already exist ---

run "existing_group_keeps_its_scaling_in_the_module" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name              = "stroom-test"
    kubernetes_version        = "1.37"
    vpc_id                    = "vpc-0123456789abcdef0"
    private_subnet_ids        = ["subnet-a", "subnet-b", "subnet-c"]
    system_node_instance_type = "t3.large"
    proxy_node_colours        = {}
    stroom_node_sets = {
      proc = { instance_types = ["r6id.8xlarge"], node_count = 4, kubernetes_version = "1.37" }
    }
  }

  override_data {
    target = data.aws_eks_clusters.all
    values = { names = ["other-cluster", "stroom-test"] }
  }

  override_data {
    target = data.aws_eks_node_groups.existing[0]
    values = { names = ["system-20261030101010123400000001", "stroom-proc-az1-20261030101010123400000002", "stroom-proc-az2-20261030101010123400000003", "stroom-proc-az3-20261030101010123400000004"] }
  }

  override_data {
    target = data.aws_eks_node_group.existing["system"]
    values = { node_group_name = "system-20261030101010123400000001", scaling_config = [{ min_size = 3, max_size = 3, desired_size = 3 }], subnet_ids = ["subnet-a", "subnet-b", "subnet-c"] }
  }

  override_data {
    target = data.aws_eks_node_group.existing["stroom-proc-az1"]
    values = { node_group_name = "stroom-proc-az1-20261030101010123400000002", scaling_config = [{ min_size = 1, max_size = 1, desired_size = 1 }], subnet_ids = ["subnet-a"] }
  }

  override_data {
    target = data.aws_eks_node_group.existing["stroom-proc-az2"]
    values = { scaling_config = [{ min_size = 1, max_size = 1, desired_size = 1 }], subnet_ids = ["subnet-b"] }
  }

  override_data {
    target = data.aws_eks_node_group.existing["stroom-proc-az3"]
    values = { scaling_config = [{ min_size = 1, max_size = 1, desired_size = 1 }], subnet_ids = ["subnet-c"] }
  }

  assert {
    condition     = keys(data.aws_eks_node_group.existing) == ["stroom-proc-az1", "stroom-proc-az2", "stroom-proc-az3", "system"]
    error_message = "Expected each existing node group to be found by its name prefix."
  }

  assert {
    # 4 nodes over 3 AZs: az1 grows from 1 to 2. The module keeps the group's
    # current scaling (so it sends no update EKS would refuse); the AWS CLI
    # resizes it.
    condition = (
      local.eks_managed_node_groups["stroom-proc-az1"].min_size == 1 &&
      local.eks_managed_node_groups["stroom-proc-az1"].max_size == 1 &&
      terraform_data.node_group_scaling["stroom-proc-az1"].triggers_replace.size == 2 &&
      terraform_data.node_group_scaling["stroom-proc-az2"].triggers_replace.size == 1
    )
    error_message = "Expected the module to keep az1's current size and terraform_data to resize it to 2."
  }

  assert {
    # The system group keeps AWS's size (3) in the module; terraform_data sets
    # the configured 2.
    condition     = local.eks_managed_node_groups["system"].min_size == 3 && terraform_data.node_group_scaling["system"].triggers_replace.size == 2
    error_message = "Expected the system group's current size in the module and the configured size in terraform_data."
  }
}

run "proxy_count_lowered_on_an_existing_cluster" {
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
      blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37", nodes_per_az = 1 }
    }
  }

  override_data {
    target = data.aws_eks_clusters.all
    values = { names = ["stroom-test"] }
  }

  override_data {
    target = data.aws_eks_node_groups.existing[0]
    values = { names = ["proxy-blue-az1-20261030101010123400000002"] }
  }

  override_data {
    target = data.aws_eks_node_group.existing["proxy-blue-az1"]
    values = { scaling_config = [{ min_size = 2, max_size = 2, desired_size = 2 }], subnet_ids = ["subnet-a"] }
  }

  assert {
    condition = (
      local.eks_managed_node_groups["proxy-blue-az1"].min_size == 2 &&
      local.eks_managed_node_groups["proxy-blue-az1"].desired_size == 2 &&
      terraform_data.node_group_scaling["proxy-blue-az1"].triggers_replace.size == 1
    )
    error_message = "Expected the module to keep the group's current size and terraform_data to lower it to 1."
  }
}

run "rejects_moving_a_proxy_group_to_another_subnet" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  # existing_private_subnet_ids reordered
  variables {
    cluster_name       = "stroom-test"
    kubernetes_version = "1.37"
    vpc_id             = "vpc-0123456789abcdef0"
    private_subnet_ids = ["subnet-b", "subnet-a", "subnet-c"]
    proxy_node_colours = {
      blue = { instance_types = ["m6i.xlarge"], kubernetes_version = "1.37" }
    }
  }

  override_data {
    target = data.aws_eks_clusters.all
    values = { names = ["stroom-test"] }
  }

  override_data {
    target = data.aws_eks_node_groups.existing[0]
    values = { names = ["proxy-blue-az1-20261030101010123400000002", "proxy-blue-az2-20261030101010123400000003"] }
  }

  override_data {
    target = data.aws_eks_node_group.existing["proxy-blue-az1"]
    values = { scaling_config = [{ min_size = 1, max_size = 1, desired_size = 1 }], subnet_ids = ["subnet-a"] }
  }

  override_data {
    target = data.aws_eks_node_group.existing["proxy-blue-az2"]
    values = { scaling_config = [{ min_size = 1, max_size = 1, desired_size = 1 }], subnet_ids = ["subnet-b"] }
  }

  expect_failures = [terraform_data.node_group_scaling["proxy-blue-az1"], terraform_data.node_group_scaling["proxy-blue-az2"]]
}

run "rejects_shrinking_a_stroom_group" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  variables {
    cluster_name              = "stroom-test"
    kubernetes_version        = "1.37"
    vpc_id                    = "vpc-0123456789abcdef0"
    private_subnet_ids        = ["subnet-a", "subnet-b", "subnet-c"]
    system_node_instance_type = "t3.large"
    proxy_node_colours        = {}
    stroom_node_sets = {
      proc = { instance_types = ["r6id.8xlarge"], node_count = 3, kubernetes_version = "1.37" }
    }
  }

  override_data {
    target = data.aws_eks_clusters.all
    values = { names = ["stroom-test"] }
  }

  override_data {
    target = data.aws_eks_node_groups.existing[0]
    values = { names = ["stroom-proc-az1-20261030101010123400000002"] }
  }

  override_data {
    target = data.aws_eks_node_group.existing["stroom-proc-az1"]
    values = { scaling_config = [{ min_size = 2, max_size = 2, desired_size = 2 }], subnet_ids = ["subnet-a"] }
  }

  expect_failures = [terraform_data.node_group_scaling["stroom-proc-az1"]]
}

run "rejects_removing_a_stroom_group" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  # Down from three subnets to two: proc's az3 group would go.
  variables {
    cluster_name              = "stroom-test"
    kubernetes_version        = "1.37"
    vpc_id                    = "vpc-0123456789abcdef0"
    private_subnet_ids        = ["subnet-a", "subnet-b"]
    system_node_instance_type = "t3.large"
    proxy_node_colours        = {}
    stroom_node_sets = {
      proc = { instance_types = ["r6id.8xlarge"], node_count = 4, kubernetes_version = "1.37" }
    }
  }

  override_data {
    target = data.aws_eks_clusters.all
    values = { names = ["stroom-test"] }
  }

  override_data {
    target = data.aws_eks_node_groups.existing[0]
    values = { names = ["stroom-proc-az1-20261030101010123400000002", "stroom-proc-az2-20261030101010123400000003", "stroom-proc-az3-20261030101010123400000004"] }
  }

  override_data {
    target = data.aws_eks_node_group.existing["stroom-proc-az1"]
    values = { scaling_config = [{ min_size = 2, max_size = 2, desired_size = 2 }], subnet_ids = ["subnet-a"] }
  }

  override_data {
    target = data.aws_eks_node_group.existing["stroom-proc-az2"]
    values = { scaling_config = [{ min_size = 1, max_size = 1, desired_size = 1 }], subnet_ids = ["subnet-b"] }
  }

  expect_failures = [output.stroom_node_sets]
}

run "allows_removing_a_whole_node_set" {
  command = plan

  module {
    source = "../../modules/eks"
  }

  # The ui node set is removed (40-stroom's guards decide whether that's allowed).
  variables {
    cluster_name              = "stroom-test"
    kubernetes_version        = "1.37"
    vpc_id                    = "vpc-0123456789abcdef0"
    private_subnet_ids        = ["subnet-a", "subnet-b", "subnet-c"]
    system_node_instance_type = "t3.large"
    proxy_node_colours        = {}
    stroom_node_sets = {
      proc = { instance_types = ["r6id.8xlarge"], node_count = 1, kubernetes_version = "1.37" }
    }
  }

  override_data {
    target = data.aws_eks_clusters.all
    values = { names = ["stroom-test"] }
  }

  override_data {
    target = data.aws_eks_node_groups.existing[0]
    values = { names = ["stroom-proc-az1-20261030101010123400000002", "stroom-ui-az1-20261030101010123400000003"] }
  }

  override_data {
    target = data.aws_eks_node_group.existing["stroom-proc-az1"]
    values = { scaling_config = [{ min_size = 1, max_size = 1, desired_size = 1 }], subnet_ids = ["subnet-a"] }
  }

  assert {
    condition     = local.removed_stroom_node_groups == []
    error_message = "Removing a whole node set isn't a reshuffle of its AZ groups."
  }
}

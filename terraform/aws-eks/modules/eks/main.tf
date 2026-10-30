locals {
  # Proxy nodes carry this label and taint so only Stroom-Proxy pods (which
  # tolerate the taint) run on them. Cluster services go to the system nodes.
  proxy_node_label  = { key = "workload", value = "stroom-proxy" }
  system_node_label = { key = "workload", value = "system" }
  colour_label_key  = "stroom-proxy/colour"

  # Every proxy colour gets a node group in each private subnet (AZ), named
  # proxy-<colour>-az<n>, so each AZ that holds a proxy volume has a node.
  proxy_node_groups = merge([
    for colour_name, colour in var.proxy_node_colours : {
      for i, subnet_id in var.private_subnet_ids : "proxy-${colour_name}-az${i + 1}" => {
        colour_name = colour_name
        colour      = colour
        subnet_id   = subnet_id
      }
    }
  ]...)

  # Stroom nodes carry this label and taint, and a label naming their node set,
  # so each Stroom node set's pods run only on its own nodes.
  stroom_node_label     = { key = "workload", value = "stroom" }
  node_set_label_key    = "stroom/node-set"
  stroom_cluster_needed = length(var.stroom_node_sets) > 0

  # Each Stroom node set's nodes are spread over the AZs in order: AZ i gets
  # floor(n / azs) nodes, plus one for the first n % azs AZs. A node group is
  # created only for AZs that get a node, named stroom-<set>-az<n>. A group's
  # instance types, Kubernetes version and AMI are the set's, or those in the
  # set's az_overrides for that group, so an upgrade can go one AZ at a time.
  stroom_node_groups = merge([
    for set_name, set in var.stroom_node_sets : {
      for i, subnet_id in var.private_subnet_ids : "stroom-${set_name}-az${i + 1}" => {
        set_name   = set_name
        set        = set
        subnet_id  = subnet_id
        node_count = floor(set.node_count / length(var.private_subnet_ids)) + (i < set.node_count % length(var.private_subnet_ids) ? 1 : 0)

        instance_types      = try(set.az_overrides["az${i + 1}"].instance_types, null) != null ? set.az_overrides["az${i + 1}"].instance_types : set.instance_types
        kubernetes_version  = try(set.az_overrides["az${i + 1}"].kubernetes_version, null) != null ? set.az_overrides["az${i + 1}"].kubernetes_version : set.kubernetes_version
        ami_release_version = try(set.az_overrides["az${i + 1}"].ami_release_version, null) != null ? set.az_overrides["az${i + 1}"].ami_release_version : set.ami_release_version
      } if floor(set.node_count / length(var.private_subnet_ids)) + (i < set.node_count % length(var.private_subnet_ids) ? 1 : 0) > 0
    }
  ]...)

  # nodeadm builds a RAID0 array from the instance-store NVMe disks and puts
  # kubelet and containerd on it, so emptyDir volumes land on NVMe.
  nvme_raid0_nodeadm = [{
    content_type = "application/node.eks.aws"
    content      = <<-EOT
      ---
      apiVersion: node.eks.aws/v1alpha1
      kind: NodeConfig
      spec:
        instance:
          localStorage:
            strategy: RAID0
    EOT
  }]

  # IMDSv2 only, hop limit 1: pods can't reach the node's instance role and
  # must use Pod Identity for AWS access.
  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  # Pods per node (VPC CNI without prefix delegation) for common system node
  # types. With Stroom the system nodes run about 24 cluster service pods
  # (CoreDNS, the EBS and EFS CSI controllers, load balancer controller,
  # External Secrets, CloudWatch, cert-manager, trust-manager, metrics-server,
  # the Stroom operator, 40-stroom's Jobs) plus 7 DaemonSet pods per node, and
  # need some headroom for rolling updates.
  max_pods_by_instance_type = {
    "t3.medium"  = 17, "t3.large" = 35, "t3.xlarge" = 58, "t3.2xlarge" = 58
    "t3a.medium" = 17, "t3a.large" = 35, "t3a.xlarge" = 58, "t3a.2xlarge" = 58
    "m5.large"   = 29, "m5.xlarge" = 58, "m5.2xlarge" = 58
    "m6i.large"  = 29, "m6i.xlarge" = 58, "m6i.2xlarge" = 58
    "m6a.large"  = 29, "m6a.xlarge" = 58, "m6a.2xlarge" = 58
    "m7i.large"  = 29, "m7i.xlarge" = 58, "m7i.2xlarge" = 58
    "m7a.large"  = 29, "m7a.xlarge" = 58, "m7a.2xlarge" = 58
    "c6i.large"  = 29, "c6i.xlarge" = 58, "c6i.2xlarge" = 58
    "c7i.large"  = 29, "c7i.xlarge" = 58, "c7i.2xlarge" = 58
    "r6i.large"  = 29, "r6i.xlarge" = 58, "r6i.2xlarge" = 58
  }
  system_daemonset_pods = 7
  stroom_system_pods    = 32

  # Every node group has a fixed size (min = max = desired). Stroom groups may
  # only grow, and a proxy or Stroom group must stay in its subnet (AZ).
  node_group_sizes = merge(
    { system = { size = var.system_node_count, subnet_id = null, stroom = false } },
    { for k, g in local.proxy_node_groups : k => { size = g.colour.nodes_per_az, subnet_id = g.subnet_id, stroom = false } },
    { for k, g in local.stroom_node_groups : k => { size = g.node_count, subnet_id = g.subnet_id, stroom = true } },
  )
}

################################################################################
# Node group sizes
#
# The upstream module ignores changes to a node group's desired size, so it
# sends the old desired size with a new min and max, which EKS refuses
# ("minimum capacity can't be greater than desired size" when raising, the
# reverse when lowering). Instead, an existing node group is given its current
# scaling config from AWS, so the module never changes it, and
# terraform_data.node_group_scaling sets min, max and desired together with
# the AWS CLI when the configured size changes. A new node group is created
# with the configured size.
################################################################################

data "aws_region" "current" {}

# Lists the region's clusters; doesn't fail before the cluster exists.
data "aws_eks_clusters" "all" {}

data "aws_eks_node_groups" "existing" {
  count        = contains(data.aws_eks_clusters.all.names, var.cluster_name) ? 1 : 0
  cluster_name = var.cluster_name
}

locals {
  existing_node_group_names = try(data.aws_eks_node_groups.existing[0].names, [])

  # The module names each node group <key>-<unique suffix>. More than one
  # match only during a replacement; then the configured size is used.
  existing_node_group_matches = {
    for k in keys(local.node_group_sizes) : k => [
      for n in local.existing_node_group_names : n if can(regex("^${k}-[0-9a-f]+$", n))
    ]
  }
}

data "aws_eks_node_group" "existing" {
  for_each = { for k, names in local.existing_node_group_matches : k => one(names) if length(names) == 1 }

  cluster_name    = var.cluster_name
  node_group_name = each.value
}

locals {
  existing_node_groups = {
    for k, g in data.aws_eks_node_group.existing : k => {
      min_size     = g.scaling_config[0].min_size
      max_size     = g.scaling_config[0].max_size
      desired_size = g.scaling_config[0].desired_size
      subnet_ids   = g.subnet_ids
    }
  }

  # What the module is given: the current scaling config of an existing node
  # group, the configured size of a new one.
  node_group_scaling = {
    for k, s in local.node_group_sizes : k => lookup(local.existing_node_groups, k, null) != null ? {
      min_size     = local.existing_node_groups[k].min_size
      max_size     = local.existing_node_groups[k].max_size
      desired_size = local.existing_node_groups[k].desired_size
      } : {
      min_size     = s.size
      max_size     = s.size
      desired_size = s.size
    }
  }

  # Existing Stroom node groups of a configured node set that are no longer
  # configured, e.g. after the number or order of subnets changed.
  removed_stroom_node_groups = [
    for n in local.existing_node_group_names : n
    if anytrue([for s in keys(var.stroom_node_sets) : can(regex("^stroom-${s}-az[0-9]+-[0-9a-f]+$", n))]) &&
    !anytrue([for k in keys(local.stroom_node_groups) : can(regex("^${k}-[0-9a-f]+$", n))])
  ]
}

check "system_node_capacity" {
  assert {
    condition     = length(var.stroom_node_sets) == 0 || contains(keys(local.max_pods_by_instance_type), var.system_node_instance_type)
    error_message = "Can't check that ${var.system_node_count} × ${var.system_node_instance_type} system nodes have room for Stroom's cluster services: the type isn't in modules/eks's table of pods per node. They need system_node_count × (max pods − ${local.system_daemonset_pods}) ≥ ${local.stroom_system_pods}."
  }
}

resource "terraform_data" "node_group_scaling" {
  for_each = local.node_group_sizes

  triggers_replace = { size = each.value.size }

  input = {
    # Depends on the node group, so this runs after the module has created or
    # updated it.
    node_group_id = module.eks.eks_managed_node_groups[each.key].node_group_id
    region        = data.aws_region.current.region
    size          = each.value.size
  }

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    environment = {
      NODE_GROUP_ID = self.input.node_group_id
      AWS_REGION    = self.input.region
      SIZE          = self.input.size
      AWS_PAGER     = ""
    }
    command = <<-EOT
      set -eu
      cluster="$${NODE_GROUP_ID%%:*}"
      node_group="$${NODE_GROUP_ID#*:}"
      current=$(aws eks describe-nodegroup --region "$AWS_REGION" --cluster-name "$cluster" --nodegroup-name "$node_group" \
        --query 'nodegroup.scalingConfig.[minSize,maxSize,desiredSize]' --output text)
      set -- $current
      if [ "$1" = "$SIZE" ] && [ "$2" = "$SIZE" ] && [ "$3" = "$SIZE" ]; then
        echo "$node_group: already min = max = desired = $SIZE"
        exit 0
      fi
      echo "$node_group: scaling from min $1, max $2, desired $3 to $SIZE"
      update=$(aws eks update-nodegroup-config --region "$AWS_REGION" --cluster-name "$cluster" --nodegroup-name "$node_group" \
        --scaling-config "minSize=$SIZE,maxSize=$SIZE,desiredSize=$SIZE" --query 'update.id' --output text)
      i=0
      while :; do
        status=$(aws eks describe-update --region "$AWS_REGION" --name "$cluster" --nodegroup-name "$node_group" \
          --update-id "$update" --query 'update.status' --output text)
        case "$status" in
          Successful) echo "$node_group: scaled to $SIZE"; exit 0 ;;
          Failed|Cancelled)
            aws eks describe-update --region "$AWS_REGION" --name "$cluster" --nodegroup-name "$node_group" \
              --update-id "$update" --query 'update.errors' --output text >&2
            echo "$node_group: scaling update $update $status" >&2
            exit 1 ;;
        esac
        i=$((i + 1))
        if [ "$i" -ge 240 ]; then
          echo "$node_group: scaling update $update still $status after an hour" >&2
          exit 1
        fi
        sleep 15
      done
    EOT
  }

  lifecycle {
    precondition {
      # A proxy or Stroom node group that moved to another subnet would be
      # replaced in another AZ, away from its pods' EBS volumes.
      condition = (
        each.value.subnet_id == null ||
        lookup(local.existing_node_groups, each.key, null) == null ||
        contains(try(local.existing_node_groups[each.key].subnet_ids, []), coalesce(each.value.subnet_id, "-"))
      )
      error_message = "Node group ${each.key} would move to subnet ${coalesce(each.value.subnet_id, "-")}, away from its nodes' AZ and the EBS volumes there. Keep the private subnets' number and order (az_count, azs, existing_private_subnet_ids) as they were when the cluster was created; add AZs only at the end. To move proxy nodes, use a new colour."
    }

    precondition {
      # Stroom nodes own their index shards, so a Stroom node group never shrinks.
      condition     = !each.value.stroom || each.value.size >= try(local.existing_node_groups[each.key].min_size, 0)
      error_message = "Stroom node group ${each.key} would shrink from ${try(local.existing_node_groups[each.key].min_size, 0)} to ${each.value.size} nodes. Stroom nodes own their index shards, so a node set's node_count may only grow, and changing the number of AZs or subnets reshuffles the node groups. Removing a Stroom node is a manual runbook."
    }
  }
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.29.0"

  name               = var.cluster_name
  kubernetes_version = var.kubernetes_version

  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids

  endpoint_private_access      = true
  endpoint_public_access       = length(var.api_allowed_cidrs) > 0
  endpoint_public_access_cidrs = var.api_allowed_cidrs

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = true
  # Keyed by ARN, so adding or removing one admin doesn't recreate the others.
  access_entries = {
    for arn in var.admin_principal_arns : arn => {
      principal_arn = arn
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # Envelope encryption of Kubernetes Secrets with a module-managed KMS key.
  encryption_config = { resources = ["secrets"] }

  enabled_log_types                      = var.cluster_log_types
  create_cloudwatch_log_group            = length(var.cluster_log_types) > 0
  cloudwatch_log_group_retention_in_days = var.cluster_log_retention_days

  # All workload AWS access uses EKS Pod Identity, not IRSA.
  enable_irsa = false

  addons = merge({
    vpc-cni = {
      before_compute = true
      # Network policy enforcement is needed for the proxy NetworkPolicy.
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
    eks-pod-identity-agent = {
      before_compute = true
    }
    kube-proxy = {}
    coredns    = {}
    aws-ebs-csi-driver = {
      configuration_values = jsonencode({
        # The node DaemonSet must run on the tainted proxy nodes to mount their volumes.
        node = { tolerateAllTaints = true }
      })
      pod_identity_association = [{
        role_arn        = aws_iam_role.ebs_csi.arn
        service_account = "ebs-csi-controller-sa"
      }]
    }
    }, local.stroom_cluster_needed ? {
    # Stroom's shared stream volume. The node DaemonSet tolerates all taints by
    # default, so it runs on the Stroom nodes.
    aws-efs-csi-driver = {
      pod_identity_association = [{
        role_arn        = aws_iam_role.efs_csi[0].arn
        service_account = "efs-csi-controller-sa"
      }]
    }
  } : {})

  eks_managed_node_groups = local.eks_managed_node_groups

  tags = var.tags
}

locals {
  eks_managed_node_groups = merge(
    {
      # Stateless cluster services: updated in place by managed node group
      # rolling updates, including to the latest AMI for the cluster version.
      system = {
        name           = "system"
        instance_types = [var.system_node_instance_type]
        capacity_type  = "ON_DEMAND"
        min_size       = local.node_group_scaling["system"].min_size
        max_size       = local.node_group_scaling["system"].max_size
        desired_size   = local.node_group_scaling["system"].desired_size

        labels = { (local.system_node_label.key) = local.system_node_label.value }

        block_device_mappings = {
          xvda = {
            device_name = "/dev/xvda"
            ebs = {
              volume_size           = 30
              volume_type           = "gp3"
              encrypted             = true
              delete_on_termination = true
            }
          }
        }
        metadata_options = local.metadata_options
        update_config    = { max_unavailable = 1 }
      }
    },
    {
      # One node group per colour per AZ. Nothing about a colour's nodes changes
      # after creation (Kubernetes version and AMI are fixed); node upgrades come
      # from a new colour (blue/green).
      for k, g in local.proxy_node_groups : k => {
        name           = k
        subnet_ids     = [g.subnet_id]
        instance_types = g.colour.instance_types
        capacity_type  = g.colour.capacity_type
        min_size       = local.node_group_scaling[k].min_size
        max_size       = local.node_group_scaling[k].max_size
        desired_size   = local.node_group_scaling[k].desired_size

        kubernetes_version             = g.colour.kubernetes_version
        ami_release_version            = g.colour.ami_release_version
        use_latest_ami_release_version = false

        labels = {
          (local.proxy_node_label.key) = local.proxy_node_label.value
          (local.colour_label_key)     = g.colour_name
        }
        taints = {
          proxy = {
            key    = local.proxy_node_label.key
            value  = local.proxy_node_label.value
            effect = "NO_SCHEDULE"
          }
        }

        block_device_mappings = {
          xvda = {
            device_name = "/dev/xvda"
            ebs = {
              volume_size           = g.colour.root_volume_gb
              volume_type           = "gp3"
              encrypted             = true
              delete_on_termination = true
            }
          }
        }
        metadata_options = local.metadata_options
        update_config    = { max_unavailable = 1 }
      }
    },
    {
      # One node group per Stroom node set per AZ that has nodes. The Kubernetes
      # version and AMI are fixed, so only a deliberate change replaces the
      # nodes: one at a time, each Stroom pod drained first and moving to the
      # new node in the same AZ with its EBS volume. Each AZ group is changed
      # on its own through the set's az_overrides, as the groups are updated
      # in parallel.
      for k, g in local.stroom_node_groups : k => {
        name           = k
        subnet_ids     = [g.subnet_id]
        instance_types = g.instance_types
        capacity_type  = "ON_DEMAND"
        min_size       = local.node_group_scaling[k].min_size
        max_size       = local.node_group_scaling[k].max_size
        desired_size   = local.node_group_scaling[k].desired_size

        kubernetes_version             = g.kubernetes_version
        ami_release_version            = g.ami_release_version
        use_latest_ami_release_version = false

        cloudinit_pre_nodeadm = local.nvme_raid0_nodeadm

        labels = {
          (local.stroom_node_label.key) = local.stroom_node_label.value
          (local.node_set_label_key)    = g.set_name
        }
        taints = {
          stroom = {
            key    = local.stroom_node_label.key
            value  = local.stroom_node_label.value
            effect = "NO_SCHEDULE"
          }
        }

        block_device_mappings = {
          xvda = {
            device_name = "/dev/xvda"
            ebs = {
              volume_size           = g.set.root_volume_gb
              volume_type           = "gp3"
              encrypted             = true
              delete_on_termination = true
            }
          }
        }
        metadata_options = local.metadata_options
        update_config    = { max_unavailable = 1 }
      }
    },
  )
}

# Pod Identity role for the EBS CSI controller.
data "aws_iam_policy_document" "pod_identity_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi" {
  name_prefix        = "${var.cluster_name}-ebs-csi-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# Pod Identity role for the EFS CSI controller, which manages EFS access points
# for dynamically provisioned volumes. Only with Stroom node sets.
resource "aws_iam_role" "efs_csi" {
  count              = local.stroom_cluster_needed ? 1 : 0
  name_prefix        = "${var.cluster_name}-efs-csi-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_trust.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  count      = local.stroom_cluster_needed ? 1 : 0
  role       = aws_iam_role.efs_csi[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

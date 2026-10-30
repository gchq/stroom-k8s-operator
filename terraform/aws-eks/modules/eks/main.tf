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
  # created only for AZs that get a node, named stroom-<set>-az<n>.
  stroom_node_groups = merge([
    for set_name, set in var.stroom_node_sets : {
      for i, subnet_id in var.private_subnet_ids : "stroom-${set_name}-az${i + 1}" => {
        set_name   = set_name
        set        = set
        subnet_id  = subnet_id
        node_count = floor(set.node_count / length(var.private_subnet_ids)) + (i < set.node_count % length(var.private_subnet_ids) ? 1 : 0)
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

  eks_managed_node_groups = merge(
    {
      # Stateless cluster services: updated in place by managed node group
      # rolling updates, including to the latest AMI for the cluster version.
      system = {
        name           = "system"
        instance_types = [var.system_node_instance_type]
        capacity_type  = "ON_DEMAND"
        min_size       = var.system_node_count
        max_size       = var.system_node_count
        desired_size   = var.system_node_count

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
        min_size       = g.colour.nodes_per_az
        max_size       = g.colour.nodes_per_az
        desired_size   = g.colour.nodes_per_az

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
      # new node in the same AZ with its EBS volume.
      for k, g in local.stroom_node_groups : k => {
        name           = k
        subnet_ids     = [g.subnet_id]
        instance_types = g.set.instance_types
        capacity_type  = "ON_DEMAND"
        min_size       = g.node_count
        max_size       = g.node_count
        desired_size   = g.node_count

        kubernetes_version             = g.set.kubernetes_version
        ami_release_version            = g.set.ami_release_version
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

  tags = var.tags
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

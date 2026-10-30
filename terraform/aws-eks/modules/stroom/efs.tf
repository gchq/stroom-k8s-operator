################################################################################
# Shared stream volume on EFS (design 5.3): a file system, a mount target per
# AZ, and an access point that makes every file uid/gid 1000 (the stroom user).
# A static PersistentVolume binds it, so Terraform owns the file system.
################################################################################

resource "aws_kms_key" "efs" {
  description             = "Stroom stream volume (${var.name})"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_efs_file_system" "stream" {
  creation_token  = "${var.name}-stroom-stream"
  encrypted       = true
  kms_key_id      = aws_kms_key.efs.arn
  throughput_mode = var.stream_volume.throughput_mode
  tags            = merge(var.tags, { Name = "${var.name}-stroom-stream" })

  # Stroom's written streams: losing them loses processed data
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_efs_backup_policy" "stream" {
  file_system_id = aws_efs_file_system.stream.id
  backup_policy {
    status = var.stream_volume.backup ? "ENABLED" : "DISABLED"
  }
}

resource "aws_security_group" "efs" {
  name_prefix = "${var.name}-stroom-efs-"
  description = "Stroom stream volume: NFS from the cluster's nodes"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-stroom-efs" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_nodes" {
  security_group_id            = aws_security_group.efs.id
  description                  = "NFS from the cluster's nodes"
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  referenced_security_group_id = var.node_security_group_id
}

resource "aws_efs_mount_target" "stream" {
  for_each = toset(var.private_subnet_ids)

  file_system_id  = aws_efs_file_system.stream.id
  subnet_id       = each.value
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "stream" {
  file_system_id = aws_efs_file_system.stream.id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/stroom"
    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0750"
    }
  }

  tags = merge(var.tags, { Name = "${var.name}-stroom-stream" })
}

resource "kubernetes_persistent_volume_v1" "stream" {
  metadata {
    name = "${var.namespace}-${local.stream_volume_pvc_name}"
  }

  spec {
    capacity = {
      # EFS has no size; the field is required
      storage = "1Pi"
    }
    access_modes                     = ["ReadWriteMany"]
    persistent_volume_reclaim_policy = "Retain"
    storage_class_name               = ""
    mount_options                    = ["tls"]

    persistent_volume_source {
      csi {
        driver        = "efs.csi.aws.com"
        volume_handle = "${aws_efs_file_system.stream.id}::${aws_efs_access_point.stream.id}"
      }
    }

    claim_ref {
      namespace = var.namespace
      name      = local.stream_volume_pvc_name
    }
  }

  depends_on = [aws_efs_mount_target.stream]
}

resource "kubernetes_persistent_volume_claim_v1" "stream" {
  metadata {
    name      = local.stream_volume_pvc_name
    namespace = kubernetes_namespace_v1.stroom.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteMany"]
    storage_class_name = ""
    volume_name        = kubernetes_persistent_volume_v1.stream.metadata[0].name
    resources {
      requests = {
        storage = "1Pi"
      }
    }
  }
}

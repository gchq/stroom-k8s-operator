################################################################################
# RDS for MySQL 8.4 for Stroom (design section 6)
#
# One instance holding the stroom and stats schemas. The master password is
# managed by RDS in Secrets Manager; the Stroom user's password is generated
# here as an ephemeral value and written to Secrets Manager with a write-only
# argument, so neither is in Terraform state. The schemas and the Stroom user
# are created by the database init Job in 40-stroom.
################################################################################

locals {
  engine_major = regex("^[0-9]+\\.[0-9]+", var.database.engine_version)
}

resource "aws_kms_key" "db" {
  description             = "Stroom database and its secrets (${var.name})"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  tags                    = var.tags
}

resource "aws_kms_alias" "db" {
  name          = "alias/${var.name}-stroom-db"
  target_key_id = aws_kms_key.db.key_id
}

resource "aws_db_subnet_group" "db" {
  name_prefix = "${var.name}-stroom-db-"
  description = "Stroom database (${var.name})"
  subnet_ids  = var.subnet_ids
  tags        = var.tags
}

resource "aws_security_group" "db" {
  name_prefix = "${var.name}-stroom-db-"
  description = "Stroom database: MySQL from the cluster's nodes"
  vpc_id      = var.vpc_id
  tags        = merge(var.tags, { Name = "${var.name}-stroom-db" })

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_clients" {
  for_each = toset(var.client_security_group_ids)

  security_group_id            = aws_security_group.db.id
  description                  = "MySQL from the cluster's nodes"
  ip_protocol                  = "tcp"
  from_port                    = 3306
  to_port                      = 3306
  referenced_security_group_id = each.value
}

resource "aws_db_parameter_group" "db" {
  name_prefix = "${var.name}-stroom-mysql${replace(local.engine_major, ".", "")}-"
  family      = "mysql${local.engine_major}"
  description = "Stroom (${var.name})"
  tags        = var.tags

  # Stroom's docstore sets its own utf8mb4_0900_as_cs columns
  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }
  parameter {
    name  = "collation_server"
    value = "utf8mb4_0900_ai_ci"
  }
  parameter {
    name  = "max_connections"
    value = tostring(var.database.max_connections)
  }
  # Stroom's JDBC URLs and the operator verify the server's certificate
  # (serverAddress.tls), so plain connections are refused
  parameter {
    name  = "require_secure_transport"
    value = "1"
  }
  # lower_case_table_names can only be set when the instance is created;
  # RDS's default (0 on Linux) is what Stroom expects.

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "db" {
  identifier_prefix = "${var.name}-stroom-"

  engine                     = "mysql"
  engine_version             = var.database.engine_version
  auto_minor_version_upgrade = true
  instance_class             = var.database.instance_class
  multi_az                   = var.database.multi_az
  parameter_group_name       = aws_db_parameter_group.db.name

  storage_type          = "gp3"
  allocated_storage     = var.database.storage_gb
  max_allocated_storage = var.database.max_storage_gb
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.db.arn

  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  port                   = 3306

  # RDS creates the master password and keeps it in Secrets Manager
  username                      = "admin"
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.db.key_id

  backup_retention_period   = var.database.backup_retention_days
  backup_window             = var.database.backup_window
  maintenance_window        = var.database.maintenance_window
  copy_tags_to_snapshot     = true
  deletion_protection       = var.database.deletion_protection
  skip_final_snapshot       = false
  final_snapshot_identifier = "${var.name}-stroom-final"

  performance_insights_enabled    = var.database.performance_insights
  performance_insights_kms_key_id = var.database.performance_insights ? aws_kms_key.db.arn : null
  enabled_cloudwatch_logs_exports = ["error", "slowquery"]

  apply_immediately = var.database.apply_immediately
  tags              = var.tags
}

################################################################################
# The Stroom user's password: in Secrets Manager only
################################################################################

ephemeral "random_password" "app_user" {
  length = 40
  # Letters and digits only: the init Job puts it in SQL
  special = false
}

resource "aws_secretsmanager_secret" "app_user" {
  name        = "${var.secrets_name_prefix}db-${var.app_user}"
  description = "Password of the Stroom database user ${var.app_user} (${var.name})"
  kms_key_id  = aws_kms_key.db.arn
  tags        = var.tags
}

resource "aws_secretsmanager_secret_version" "app_user" {
  secret_id        = aws_secretsmanager_secret.app_user.id
  secret_string_wo = ephemeral.random_password.app_user.result
  # Bump to set a new password: the init Job then changes the user's password
  # to match, and the Stroom nodes need a rolling restart
  secret_string_wo_version = 1
}

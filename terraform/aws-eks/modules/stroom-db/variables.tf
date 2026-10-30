variable "name" {
  description = "Name of the deployment. Prefixes the database instance and its resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC of the cluster."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the database, in at least two AZs."
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "subnet_ids needs subnets in at least two AZs."
  }
}

variable "client_security_group_ids" {
  description = "Security groups allowed to connect on 3306: the cluster's node security group, which Stroom's pods, the operator and the database init Job use (VPC CNI)."
  type        = list(string)
}

variable "secrets_name_prefix" {
  description = "Secrets Manager name prefix for the Stroom database user's password, e.g. \"stroom/prod/\". The External Secrets Operator reads secrets under it."
  type        = string

  validation {
    condition     = endswith(var.secrets_name_prefix, "/")
    error_message = "secrets_name_prefix must end with \"/\"."
  }
}

variable "database" {
  description = <<-EOT
    The RDS for MySQL instance.

    engine_version          : MySQL major.minor (8.4) or a full version. Minor
                              upgrades are applied in the maintenance window.
    instance_class          : e.g. db.r6g.large.
    multi_az                : a standby in a second AZ.
    storage_gb              : allocated gp3 storage.
    max_storage_gb          : storage autoscaling limit; null = off.
    backup_retention_days   : automated backups (1-35).
    deletion_protection     : refuse to delete the instance.
    max_connections         : MySQL max_connections. Each Stroom node opens up to
                              about 30 connections per pool (stroom and stats);
                              allow for every node plus headroom.
    maintenance_window      : e.g. "sun:03:00-sun:04:00" (UTC).
    backup_window           : e.g. "01:00-02:00" (UTC).
    performance_insights    : turn on Performance Insights.
    apply_immediately       : apply changes now rather than in the maintenance window.
  EOT
  type = object({
    engine_version        = optional(string, "8.4")
    instance_class        = optional(string, "db.r6g.large")
    multi_az              = optional(bool, true)
    storage_gb            = optional(number, 200)
    max_storage_gb        = optional(number)
    backup_retention_days = optional(number, 14)
    deletion_protection   = optional(bool, true)
    max_connections       = optional(number, 1000)
    maintenance_window    = optional(string, "sun:03:00-sun:04:00")
    backup_window         = optional(string, "01:00-02:00")
    performance_insights  = optional(bool, true)
    apply_immediately     = optional(bool, false)
  })
  default = {}

  validation {
    condition     = can(regex("^8\\.4(\\.[0-9]+)?$", var.database.engine_version))
    error_message = "database.engine_version must be MySQL 8.4 (\"8.4\" or e.g. \"8.4.7\"), the version Stroom is tested with."
  }

  validation {
    condition     = var.database.backup_retention_days >= 1 && var.database.backup_retention_days <= 35
    error_message = "database.backup_retention_days must be 1-35: automated backups can't be turned off."
  }

  validation {
    condition     = var.database.storage_gb >= 20 && (var.database.max_storage_gb == null ? true : var.database.max_storage_gb > var.database.storage_gb)
    error_message = "database.storage_gb must be at least 20, and max_storage_gb (if set) larger than it."
  }
}

variable "app_user" {
  description = "Name of the database user Stroom connects as. Created by the database init Job in 40-stroom; this module only creates its password."
  type        = string
  default     = "stroomuser"
}

variable "tags" {
  description = "Tags added to every resource."
  type        = map(string)
  default     = {}
}

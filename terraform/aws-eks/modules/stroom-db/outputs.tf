output "host" {
  description = "Host name of the database."
  value       = aws_db_instance.db.address
}

output "port" {
  description = "Port of the database."
  value       = aws_db_instance.db.port
}

output "master_username" {
  description = "Master user name."
  value       = aws_db_instance.db.username
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret holding the master user's credentials (JSON with username and password), managed by RDS."
  value       = aws_db_instance.db.master_user_secret[0].secret_arn
}

output "app_user" {
  description = "Name of the Stroom database user."
  value       = var.app_user
}

output "app_user_secret_name" {
  description = "Secrets Manager name of the Stroom database user's password (a plain string)."
  value       = aws_secretsmanager_secret.app_user.name
}

output "app_user_secret_arn" {
  description = "ARN of the Stroom database user's password secret."
  value       = aws_secretsmanager_secret.app_user.arn
}

output "app_user_password_version" {
  description = "Generation of the Stroom database user's password: 40-stroom re-runs the init Job and restarts the Stroom nodes when it changes."
  value       = aws_secretsmanager_secret_version.app_user.secret_string_wo_version
}

output "kms_key_arn" {
  description = "KMS key of the database storage and its secrets."
  value       = aws_kms_key.db.arn
}

output "security_group_id" {
  description = "Security group of the database."
  value       = aws_security_group.db.id
}

output "instance_id" {
  description = "Identifier of the database instance, for alarms."
  value       = aws_db_instance.db.identifier
}

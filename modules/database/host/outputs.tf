output "database_instance_id" {
  description = "Instance ID of the database host."
  value       = module.database_host.instance_id
}

output "secrets_vault_secret_arn" {
  description = "ARN of the secret holding the database's administrator credentials."
  value       = module.secrets_vault.secret_arn
}

output "update_document_name" {
  description = "Name of the SSM document that runs the database deploy. The platforms pipeline sends this after publishing engine definitions."
  value       = aws_ssm_document.database_update.name
}

output "refresh_scripts_document_name" {
  description = "Name of the SSM document that re-downloads the database host's platform scripts."
  value       = aws_ssm_document.database_refresh_scripts.name
}

output "database_workspace" {
  description = "Directory on the database host holding the scripts, .env and synced engine definitions."
  value       = local.database_workspace
}

output "data_root" {
  description = "Directory every engine keeps its data under, available to engine compose files as DATA_ROOT."
  value       = local.data_root
}

output "host" {
  description = "Address services use to reach the database host: db.<private_domain> when the private DNS record is registered, otherwise the instance's private IP."
  value       = var.db_enable_private_dns_registration ? local.db_private_dns_record_name : module.database_host.private_ip
}

# -----------------------------------------------------------------------------
# Provisioning Document
# -----------------------------------------------------------------------------

output "provision_document_name" {
  description = "SSM document that creates one service's database and user. A service's infrastructure repository sends it after publishing its request."
  value       = aws_ssm_document.database_provision.name
}

output "provision_people_document_name" {
  description = "Name of the SSM document that brings the team's logins on every running engine in line with core's people secret."
  value       = aws_ssm_document.database_provision_people.name
}

output "project_name" {
  description = "Outputs the name of the project referenced by related services."
  value       = var.project_name
}

output "environment" {
  description = "Outputs the deployment environment of the project referenced by related services."
  value       = local.environment
}

output "domain_name" {
  description = "This is the fully qualified domain name of the project for reference by all other related services."
  value       = var.domain_name
}

output "core_deploy_role_arn" {
  description = "ARN of the core deployment role. Set this repository's TF_AWS_ROLE_ARN secret to this value."
  value       = module.github_oidc.core_deploy_role_arn
}

output "service_role_arns" {
  description = "Map of service repository name to its IAM role ARN. Set each service repository's own AWS_ROLE_ARN secret/variable to its corresponding value here."
  value       = module.github_service_roles.service_role_arns
}

output "private_alb_https_listener_arn" {
  description = "ARN of the private-tier ALB's HTTPS listener (port 443)."
  value       = module.edge.private_alb_https_listener_arn
  sensitive   = true
}

output "internal_alb_https_listener_arn" {
  description = "ARN of the internal-tier ALB's HTTPS listener (port 443)."
  value       = module.edge.internal_alb_https_listener_arn
  sensitive   = true
}

output "people_provisioning" {
  description = "What core's apply calls to bring the team's logins in line with the people secret: the database host, the SSM document that refreshes its scripts, and the one that provisions people on every running engine."
  value = {
    kind             = "host"
    instance_id      = module.database.database_instance_id
    refresh_document = module.database.refresh_scripts_document_name
    people_document  = module.database.provision_people_document_name
  }
}

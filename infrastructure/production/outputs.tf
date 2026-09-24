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

output "database_hosts" {
  description = "Address of each active engine's instance, by engine."
  value       = { for engine, database in module.database : engine => database.address }
}

output "database_provision_function_names" {
  description = "Lambda that creates a service's database and user, by engine."
  value       = { for engine, provisioning in module.database_provisioning : engine => provisioning.function_name }
}

output "ami_parameter_name" {
  description = "SSM parameter holding the golden AMI's ID. A service's launch template reads this."
  value       = module.image.parameter_name
}

output "deploy_bucket_name" {
  description = "Bucket holding the platform scripts a service's hosts install."
  value       = module.deploy.bucket_name
}

output "people_provisioning" {
  description = "What core's apply calls to bring the team's logins in line with the people secret: each engine's provisioning function, and its database, whose state is checked first (a stopped staging database is skipped)."
  value = {
    kind = "managed"
    engines = {
      for engine, provisioning in module.database_provisioning : engine => {
        function      = provisioning.function_name
        database_kind = engine == "mongodb" ? "docdb" : "rds"
        database_id   = engine == "mongodb" ? module.documentdb[0].id : module.database[engine].id
      }
    }
  }
}

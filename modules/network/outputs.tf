output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc_base.vpc_id
}

output "public_subnet_ids" {
  description = "Public tier subnet IDs."
  value       = module.vpc_base.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private tier subnet IDs."
  value       = module.vpc_base.private_subnet_ids
}

output "internal_subnet_ids" {
  description = "Internal tier subnet IDs."
  value       = module.vpc_base.internal_subnet_ids
}

output "isolated_subnet_ids" {
  description = "Isolated tier subnet IDs."
  value       = module.vpc_base.isolated_subnet_ids
}

output "public_security_group_id" {
  description = "Security group ID for the public tier."
  value       = module.public_sg.security_group_id
}

output "private_security_group_id" {
  description = "Security group ID for the private tier."
  value       = module.private_sg.security_group_id
}

output "internal_security_group_id" {
  description = "Security group ID for the internal tier."
  value       = module.internal_sg.security_group_id
}

output "isolated_security_group_id" {
  description = "Security group ID for the isolated tier."
  value       = module.isolated_sg.security_group_id
}

output "tools_security_group_id" {
  description = "Security group worn by the team's own tools. The databases and the VPC endpoints admit it."
  value       = module.tools_sg.security_group_id
}

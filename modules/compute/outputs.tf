output "ami_parameter_name" {
  description = "SSM parameter holding the golden AMI's ID. A service's launch template reads this, so a rebuild reaches it on the next plan; a copied ID would not."
  value       = module.image.parameter_name
}

output "ami_id" {
  description = "ID of the shared Ubuntu AMI. Consumed by the database domain module so the database host runs the same base image as both fleets."
  value       = module.image.ami_id
}

output "private_asg_name" {
  description = "Name of the private-tier Auto Scaling Group."
  value       = module.private_autoscaling_group.name
}

output "private_asg_arn" {
  description = "ARN of the private-tier Auto Scaling Group."
  value       = module.private_autoscaling_group.arn
}

output "internal_asg_name" {
  description = "Name of the internal-tier Auto Scaling Group."
  value       = module.internal_autoscaling_group.name
}

output "internal_asg_arn" {
  description = "ARN of the internal-tier Auto Scaling Group."
  value       = module.internal_autoscaling_group.arn
}

output "scripts_manifest_parameter" {
  description = "SSM parameter holding the SHA-256 of every platform script. A host verifies what it downloads against this before installing it."
  value       = module.deploy.scripts_manifest_parameter
}

output "deploy_bucket_name" {
  description = "Name of the fleet deploy bucket. Also holds the database host's scripts and engine definitions. Consumed by the database module and, through service_platform, by services."
  value       = module.deploy.bucket_id

  # Anything that reads this waits for the shared scripts to be uploaded.
  depends_on = [module.deploy]
}

output "deploy_bucket_arn" {
  description = "ARN of the fleet deploy bucket."
  value       = module.deploy.bucket_arn

  depends_on = [module.deploy]
}

output "fleet_update_document_name" {
  description = "Name of the SSM document that runs the fleet deploy. Services send this document, not AWS-RunShellScript, to redeploy."
  value       = aws_ssm_document.fleet_update.name
}

output "fleet_refresh_scripts_document_name" {
  description = "Name of the SSM document that re-downloads the platform scripts on running fleet hosts."
  value       = aws_ssm_document.fleet_refresh_scripts.name
}

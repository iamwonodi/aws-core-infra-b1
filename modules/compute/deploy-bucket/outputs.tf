output "bucket_id" {
  description = "The deploy bucket's name."
  value       = module.bucket.bucket_id
}

output "bucket_name" {
  description = "The deploy bucket's name."
  value       = module.bucket.bucket_id
}

output "bucket_arn" {
  description = "ARN of the deploy bucket."
  value       = module.bucket.bucket_arn
}

output "scripts_manifest_parameter" {
  description = "SSM parameter holding the SHA-256 of every platform script, keyed by S3 object. A host verifies what it downloads against this."
  value       = aws_ssm_parameter.scripts_manifest.name
}

output "deploy_lib_key" {
  description = "Key of the deploy library in the bucket."
  value       = local.deploy_lib_key
}

output "fleet_update_key" {
  description = "Key of the deploy engine in the bucket."
  value       = local.fleet_update_key
}

output "deploy_lib_sha256" {
  description = "Checksum of the deploy library, as published in the manifest."
  value       = module.platform_scripts.deploy_lib_sha256
}

output "platform_prefix" {
  description = "The reserved prefix core publishes scripts under. A host's role needs read access to it, and to nothing else in this bucket outside its own directory."
  value       = "_platform"
}

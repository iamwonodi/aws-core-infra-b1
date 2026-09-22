output "deploy_lib_path" {
  description = "Path of the shared deploy library, uploaded to S3 by the module that owns the deploy bucket."
  value       = local.deploy_lib_path
}

output "deploy_lib_sha256" {
  description = "SHA-256 of the shared deploy library, recorded in each host's scripts manifest."
  value       = filesha256(local.deploy_lib_path)
}

output "fetch_scripts_function" {
  description = "Shell source of fetch_platform_scripts, embedded in user data and in the refresh-scripts SSM documents."
  value       = file(local.fetch_scripts_path)
}

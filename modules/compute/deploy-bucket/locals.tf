locals {
  bucket_name = "${var.project_name}-${var.environment}-deploy"

  deploy_lib_key   = "_platform/lib/deploy-lib.sh"
  fleet_update_key = "_platform/fleet/update.sh"

  # Every host -- a shared fleet's, or a service's own in staging and production
  # -- verifies what it downloads against this before installing anything.
  scripts_manifest_parameter = "/${var.project_name}/platform/scripts-manifest"

  scripts_manifest = {
    (local.deploy_lib_key)   = module.platform_scripts.deploy_lib_sha256
    (local.fleet_update_key) = filesha256(var.fleet_update_script_path)
  }
}

locals {
  # Folder-scoped constant, not a variable -- see the comment on
  # variables.tf's removed environment variable for why.
  environment = "staging"
  managed_by  = "terraform"

  # Must match the bucket named in backend.tf (backend blocks cannot use
  # variables). scripts/bootstrap-environment.sh creates it with this name.
  # The engines reserve "admin", "postgres" and "root". RDS allows at most 16
  # letters, digits or underscores, which a name built from the project (up to 16
  # characters itself) could exceed, so it is fixed.
  database_admin_username = "platform_admin"

  state_bucket_name = "${var.project_name}-${local.environment}-tfstate"

  core_deploy_role_name = "${var.project_name}-${local.environment}-github-actions-core-deploy-role"

  common_tags = {
    Project     = var.project_name
    Environment = local.environment
    ManagedBy   = local.managed_by
  }

  # No fleet user-data rendering here -- this environment does not call
  # the compute domain module (see README), so there's nothing that
  # consumes a rendered user-data script or needs the account-context
  # data sources (aws_region/aws_caller_identity) that rendering used.
}

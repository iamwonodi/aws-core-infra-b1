locals {
  # Folder-scoped constant, not a variable -- see the comment on
  # variables.tf's removed environment variable for why.
  environment = "development"
  managed_by  = "terraform"

  # Must match the bucket named in backend.tf (backend blocks cannot use
  # variables). scripts/bootstrap-environment.sh creates it with this name.
  state_bucket_name = "${var.project_name}-${local.environment}-tfstate"

  core_deploy_role_name = "${var.project_name}-${local.environment}-github-actions-core-deploy-role"

  common_tags = {
    Project     = var.project_name
    Environment = local.environment
    ManagedBy   = local.managed_by
  }

  # No fleet user-data rendering here anymore -- the compute domain
  # module now owns and renders its own bootstrap script directly (it
  # lives alongside it in compute/assets/), matching how the data domain
  # module already owns and renders its own database bootstrap scripts.
  # See compute/README.md for the full picture.
}

# The monthly budget's alert addresses (MONTHLY COST BUDGET in main.tf): the
# BUDGET_ALERT_EMAILS secret, split on commas and trimmed.
locals {
  budget_alert_emails = [
    for address in split(",", var.budget_alert_emails) : trimspace(address)
    if trimspace(address) != ""
  ]
}

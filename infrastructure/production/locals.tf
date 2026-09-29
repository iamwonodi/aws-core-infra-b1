locals {
  # Folder-scoped constant, not a variable -- see the comment on
  # variables.tf's removed environment variable for why.
  environment = "production"
  managed_by  = "terraform"

  # Must match the bucket named in backend.tf (backend blocks cannot use
  # variables). scripts/bootstrap-environment.sh creates it with this name.
  # The engines reserve "admin", "postgres" and "root". RDS allows at most 16
  # letters, digits or underscores, and DocumentDB letters and digits only, so one
  # fixed name fits them all; a name built from the project could exceed RDS's 16.
  database_admin_username = "platformadmin"

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

# The managed databases (MANAGED DATABASES in main.tf).
locals {
  # Every active engine, and the ones among them that run on RDS. mongodb runs on
  # DocumentDB instead.
  database_engines   = toset(var.database_engines)
  rds_engines        = toset([for engine in var.database_engines : engine if contains(["postgres", "mysql"], engine)])
  documentdb_enabled = contains(var.database_engines, "mongodb")

  # The provisioning function speaks every engine, so each active one gets one.
  provisioned_engines = local.database_engines

  # Where each active engine is, whichever service runs it.
  database_endpoints = merge(
    {
      for engine in local.rds_engines : engine => {
        host              = module.database[engine].address
        port              = module.database[engine].port
        security_group_id = module.database[engine].security_group_id
      }
    },
    local.documentdb_enabled ? {
      mongodb = {
        host              = module.documentdb[0].endpoint
        port              = module.documentdb[0].port
        security_group_id = module.documentdb[0].security_group_id
      }
    } : {},
  )

  # The database the administrator connects to before a service's own exists.
  admin_databases = {
    postgres = "postgres"
    mysql    = "platform"
    mongodb  = "admin" # DocumentDB keeps every user there
  }

  rds_engine_settings = {
    postgres = {
      # PostgreSQL always has a "postgres" database to connect to first.
      initial_database = null
      log_exports      = ["postgresql", "upgrade"]
    }
    mysql = {
      # MySQL has no database until one is created with the instance.
      initial_database = "platform"
      # error only: the general and audit logs bill for every statement.
      log_exports = ["error"]
    }
  }
}

# The monthly budget's alert addresses (MONTHLY COST BUDGET in main.tf): the
# BUDGET_ALERT_EMAILS secret, split on commas and trimmed.
locals {
  budget_alert_emails = [
    for address in split(",", var.budget_alert_emails) : trimspace(address)
    if trimspace(address) != ""
  ]
}

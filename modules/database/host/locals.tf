locals {
  # Fixed, not caller-configurable -- consistent with how the compute
  # domain module treats its own fleet service names. See this module's
  # README for why.
  database_service_name = "database-hub"
  db_username           = "admin"

  # Password special characters, kept out of the random_password resource
  # block itself so the character set is easy to find and adjust in one
  # place.
  # Generated secrets use only letters, digits and "-_.". Characters such as $
  # and # are meaningful in the env files these values are written to (Compose
  # interpolates $ and treats # as a comment), so a password containing them
  # would be silently corrupted on its way into a container.
  specials = "-_."

  database_workspace         = "/opt/${var.project_name}/${local.database_service_name}"
  db_private_dns_record_name = "db.${var.private_domain}"

  data_volume_mount_path = (
    var.db_data_volume_mount_path != ""
    ? var.db_data_volume_mount_path
    : local.database_workspace
  )

  # Matches the exact Name tag the terraform-aws-ebs module (called by
  # compute-storage, which this database module calls as module.database_host)
  # applies to the persistent data volume: "${project}-${environment}-
  # ${service_name}-persistent-data". compute-storage has no tag
  # pass-through of its own, so this is how the DLM backup policy below
  # targets that specific volume without needing any change to
  # compute-storage or the ebs module it wraps -- if that naming pattern
  # ever changes there, it needs to change here too.
  data_volume_name = "${var.project_name}-${var.environment}-${local.database_service_name}-persistent-data"

  aws_region       = data.aws_region.current.region
  ecr_registry_url = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.aws_region}.amazonaws.com"

  ##############################################################################
  # DATABASE RUNTIME ENVIRONMENT
  ##############################################################################
  # Every engine keeps its data under here. It is on the persistent data volume
  # whenever one is mounted, and the compose guard refuses any other bind mount,
  # so an engine cannot accidentally keep its data somewhere that is lost when
  # the instance is replaced.
  data_root = "${local.data_volume_mount_path}/data"

  ##############################################################################
  # PLATFORM SCRIPTS
  #
  # The scripts live in the fleet deploy bucket (EC2 user data is capped at
  # 16 KB) and are verified against a checksum manifest in SSM. The manifest --
  # not user data -- carries the checksums, so editing a script never changes
  # this host's user data and never restarts the database host.
  #
  # deploy_lib_key must match the key the compute module uploads the shared
  # library to.
  ##############################################################################

  deploy_lib_key                 = "_platform/lib/deploy-lib.sh"
  database_update_key            = "_platform/database/update.sh"
  database_provision_key         = "_platform/database/provision.sh"
  database_provision_service_key = "_platform/database/provision-service.sh"

  update_script_path            = "${path.module}/assets/update.sh"
  provision_script_path         = "${path.module}/assets/provision.sh"
  provision_service_script_path = "${path.module}/assets/provision-service.sh"

  # Core's own provisioning script per engine: what actually creates a service's
  # database, user, password and grants. Core owns them so that every service is
  # provisioned the same way and none writes its own CREATE DATABASE.
  provisioning_scripts = {
    "_platform/database/provision-postgres.sql" = "${path.module}/assets/provisioning/provision-postgres.sql"
    "_platform/database/provision-mysql.sql"    = "${path.module}/assets/provisioning/provision-mysql.sql"
    "_platform/database/provision-mongodb.js"   = "${path.module}/assets/provisioning/provision-mongodb.js"
  }

  scripts_manifest_parameter = "/${var.project_name}/database/scripts-manifest"

  scripts_manifest = merge(
    {
      (local.deploy_lib_key)                 = module.platform_scripts.deploy_lib_sha256
      (local.database_update_key)            = filesha256(local.update_script_path)
      (local.database_provision_key)         = filesha256(local.provision_script_path)
      (local.database_provision_service_key) = filesha256(local.provision_service_script_path)
    },
    { for key, path in local.provisioning_scripts : key => filesha256(path) },
  )

  # Custom SSM documents, so that permission to trigger a database update is
  # not permission to run arbitrary commands as root on the database host.
  update_document_name    = "${var.project_name}-database-update"
  refresh_document_name   = "${var.project_name}-database-refresh-scripts"
  provision_document_name = "${var.project_name}-database-provision"

  ##############################################################################
  # RUNTIME ENVIRONMENT AND USER DATA
  ##############################################################################

  database_env = templatefile(
    "${path.module}/assets/env.tftpl",
    {
      project_name         = var.project_name
      environment          = var.environment
      service_name         = local.database_service_name
      database_workspace   = local.database_workspace
      data_root            = local.data_root
      aws_region           = local.aws_region
      deploy_bucket_name   = var.deploy_bucket_name
      ecr_registry_url     = local.ecr_registry_url
      enable_ecr_access    = var.db_enable_ecr_read_access
      require_ecr_images   = var.db_require_ecr_images
      core_root_secret_arn = module.secrets_vault.secret_arn
    }
  )

  database_user_data = templatefile(
    "${path.module}/assets/bootstrap.sh",
    {
      project_name       = var.project_name
      environment        = var.environment
      service_name       = local.database_service_name
      database_workspace = local.database_workspace
      data_root          = local.data_root

      enable_data_volume_mount = var.db_enable_data_volume_mount
      data_volume_device       = var.db_data_volume_device

      # The resolved path, not the raw variable: an empty variable means "use
      # the workspace", and the bootstrap refuses an empty mount path.
      data_volume_mount_path = local.data_volume_mount_path

      deploy_bucket_name         = var.deploy_bucket_name
      aws_region                 = local.aws_region
      scripts_manifest_parameter = local.scripts_manifest_parameter
      database_env               = local.database_env
      fetch_scripts_function     = module.platform_scripts.fetch_scripts_function
    }
  )
}

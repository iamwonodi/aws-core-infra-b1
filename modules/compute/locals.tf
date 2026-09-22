locals {
  # Fixed, not caller-configurable -- these two tiers are a structural part of
  # this project's architecture (see the README for why these two fleets exist
  # and what each one does), not an arbitrary caller choice the way
  # project_name or instance sizing are.
  private_service_name  = "private"
  internal_service_name = "internal"

  fleet_tiers = toset([local.private_service_name, local.internal_service_name])

  # One shared bucket, but each tier only ever syncs -- and is only permitted
  # to read -- its own prefix within it: private/<service>/ or
  # internal/<service>/. The reserved _platform/ prefix holds the scripts every
  # host runs. See update.sh for the sync logic this scoping depends on.

  # An explicit AMI wins; otherwise Canonical's current Ubuntu 24.04 LTS.
  # insecure_value is the parameter's non-sensitive form: an AMI ID is not secret.
  parent_image = var.ubuntu_parent_image != null ? var.ubuntu_parent_image : data.aws_ssm_parameter.ubuntu_parent_image[0].insecure_value

  aws_region       = data.aws_region.current.region
  ecr_registry_url = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${local.aws_region}.amazonaws.com"

  ##############################################################################
  # PLATFORM SCRIPTS
  #
  # The scripts live in S3 (EC2 user data is capped at 16 KB) and are verified
  # against a checksum manifest held in SSM. The manifest -- not user data --
  # carries the checksums, so editing a script never changes an instance's user
  # data and never restarts a running host.
  ##############################################################################

  update_script_path = "${path.module}/assets/update.sh"




  # SSM documents. A custom document is used instead of AWS-RunShellScript so
  # that whoever may trigger a deploy can only run update.sh (and, for the
  # refresh document, only re-download the verified scripts), never an
  # arbitrary command as root on every host.
  fleet_update_document_name  = "${var.project_name}-fleet-update"
  fleet_refresh_document_name = "${var.project_name}-fleet-refresh-scripts"

  application_root = "/opt/applications"

  ##############################################################################
  # FLEET RUNTIME ENVIRONMENT -- ONE PER TIER
  #
  # Each fleet gets its own rendered .env, differing only in FLEET_TIER -- this
  # is what update.sh reads to know which S3 prefix is actually its own.
  ##############################################################################

  fleet_env = {
    for tier in local.fleet_tiers : tier => templatefile(
      "${path.module}/assets/env.tftpl",
      {
        project_name       = var.project_name
        environment        = var.environment
        deploy_bucket_name = module.deploy.bucket_name
        fleet_tier         = tier
        aws_region         = local.aws_region
        ecr_registry_url   = local.ecr_registry_url
      }
    )
  }

  ##############################################################################
  # FLEET USER DATA -- ONE PER TIER
  #
  # Rendered internally, not passed in by the caller. Small on purpose: it only
  # installs the runtime .env and fetches the verified scripts. Only the
  # rendered .env differs between the tiers.
  ##############################################################################

  user_data = {
    for tier in local.fleet_tiers : tier => templatefile(
      "${path.module}/assets/bootstrap.sh",
      {
        project_name               = var.project_name
        deploy_bucket_name         = module.deploy.bucket_name
        aws_region                 = local.aws_region
        fleet_env                  = local.fleet_env[tier]
        scripts_manifest_parameter = module.deploy.scripts_manifest_parameter
        fetch_scripts_function     = module.platform_scripts.fetch_scripts_function
      }
    )
  }
}

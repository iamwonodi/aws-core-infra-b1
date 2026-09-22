# ------------------------------------------------------------------------------
# PLATFORM CONTRACT
#
# Everything a service repository needs to know about the environment it deploys
# onto, as ONE document. Core publishes it as an SSM parameter and services read
# it with a data source; a service never reads core's Terraform state, which
# holds every secret core generated.
#
# The module only BUILDS the document. It creates no resources, so it can be
# tested without AWS; the caller creates the parameter.
#
# CHANGING THE SHAPE: adding a field is compatible. Renaming or removing one, or
# changing its meaning, must bump schema_version, and services check the
# version they were written for (see docs/platform-contract.md).
# ------------------------------------------------------------------------------

locals {
  schema_version = 1

  parameter_name = "/${var.project_name}/platform/config"

  # SSM standard parameters hold at most 4,096 characters.
  parameter_size_limit = 4096

  config = {
    schema_version = local.schema_version

    project_name = var.project_name
    environment  = var.environment
    region       = var.aws_region
    account_id   = var.account_id

    domain_name    = var.domain_name
    private_domain = var.private_domain

    vpc_id           = var.vpc_id
    ecr_registry_url = "${var.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"

    buckets = {
      deploy = var.deploy_bucket_name
      assets = var.assets_bucket_name
    }

    hosting_model        = var.hosting_model
    service_boundary_arn = var.service_boundary_arn

    # What a service's own hosts are built from, where hosting is dedicated. Core
    # owns both so that a fix is one change rather than one per service.
    compute = {
      ami_parameter              = var.ami_parameter_name
      scripts_manifest_parameter = var.scripts_manifest_parameter
      platform_prefix            = "_platform"
    }

    fleet_update_document = var.fleet_update_document_name

    isolated = {
      security_group_id = var.isolated_security_group_id
    }

    database = {
      host = var.database_host

      # How a service's infrastructure repository creates its database. On the EC2
      # host it sends an SSM document; on a managed database it invokes a Lambda,
      # which has a container to run in. Exactly one of the two is set.
      provision_document = var.database_provision_document_name
      provision_function = var.database_provision_function_name

      # How the platforms team's pipeline applies the engines it publishes to the
      # EC2 host. Null on a managed database, which runs no published engines.
      update_document = var.database_update_document_name

      # Every managed instance, by engine. host and provision_function above keep
      # describing PostgreSQL for services written before an environment could
      # run more than one engine.
      engines = var.database_engines
    }

    tiers = var.tiers
  }

  config_json = jsonencode(local.config)
}

resource "terraform_data" "contract_invariants" {
  lifecycle {
    precondition {
      condition     = var.database_provision_document_name == null || var.database_provision_function_name == null
      error_message = "A database is provisioned either by an SSM document on the EC2 host or by a Lambda on a managed instance, never both. Set only one."
    }

    precondition {
      condition     = length(local.config_json) <= local.parameter_size_limit
      error_message = "The platform contract is ${length(local.config_json)} characters, over the ${local.parameter_size_limit} an SSM standard parameter can hold."
    }
  }
}

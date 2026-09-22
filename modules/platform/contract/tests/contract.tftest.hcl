# Run with: terraform test   (from this module's directory; no AWS access needed)

variables {
  project_name                     = "core"
  environment                      = "development"
  aws_region                       = "af-south-1"
  account_id                       = "123456789012"
  domain_name                      = "dev.example.org"
  private_domain                   = "dev.example.org"
  vpc_id                           = "vpc-0abc"
  deploy_bucket_name               = "core-development-deploy"
  ami_parameter_name               = "/core/platform/ami/ubuntu"
  scripts_manifest_parameter       = "/core/platform/scripts-manifest"
  assets_bucket_name               = "core-development-assets"
  fleet_update_document_name       = "core-fleet-update"
  isolated_security_group_id       = "sg-0iso"
  database_host                    = "db.dev.example.org"
  database_provision_document_name = "core-database-provision"

  tiers = {
    private = {
      security_group_id     = "sg-0priv"
      alb_security_group_id = "sg-0privalb"
      asg_name              = "core-development-private-asg"
      listener_arn          = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/core-private-alb-development/50dc6c495c0c9188/f2f7dc8efc522ab2"
    }
    internal = {
      security_group_id     = "sg-0int"
      alb_security_group_id = "sg-0intalb"
      asg_name              = "core-development-internal-asg"
      listener_arn          = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/core-internal-alb-development/60dc6c495c0c9188/a2f7dc8efc522ab2"
    }
  }
}

run "the_contract_has_the_documented_shape" {
  command = plan

  assert {
    condition     = output.parameter_name == "/core/platform/config"
    error_message = "the parameter must live under /<project>/platform/ with no environment segment (one account per environment)"
  }

  assert {
    condition     = jsondecode(output.config_json).schema_version == 1 && output.schema_version == 1
    error_message = "schema_version must be present and equal 1"
  }

  assert {
    condition = alltrue([
      for key in ["schema_version", "project_name", "environment", "region", "account_id", "domain_name", "private_domain", "vpc_id", "ecr_registry_url", "hosting_model", "service_boundary_arn", "compute", "buckets", "fleet_update_document", "isolated", "database", "tiers"] :
      contains(keys(jsondecode(output.config_json)), key)
    ])
    error_message = "the contract is missing a documented field"
  }

  assert {
    condition     = jsondecode(output.config_json).ecr_registry_url == "123456789012.dkr.ecr.af-south-1.amazonaws.com"
    error_message = "the ECR registry URL is derived from the account and region"
  }

  assert {
    condition     = jsondecode(output.config_json).tiers.private.asg_name == "core-development-private-asg" && jsondecode(output.config_json).tiers.internal.alb_security_group_id == "sg-0intalb"
    error_message = "tiers must be nested per tier"
  }

  assert {
    condition     = jsondecode(output.config_json).database.host == "db.dev.example.org" && jsondecode(output.config_json).database.provision_document == "core-database-provision"
    error_message = "the database host and its provisioning document must be published"
  }
}

run "the_contract_fits_an_ssm_standard_parameter" {
  command = plan

  assert {
    condition     = length(output.config_json) < 4096
    error_message = "the contract must fit a standard SSM parameter"
  }
}

run "the_image_and_the_scripts_are_published_as_parameter_names" {
  command = plan

  assert {
    condition     = jsondecode(output.config_json).compute.ami_parameter == "/core/platform/ami/ubuntu"
    error_message = "the contract must carry the AMI parameter's NAME: a copied ID would freeze a service on one image"
  }

  assert {
    condition     = jsondecode(output.config_json).compute.scripts_manifest_parameter == "/core/platform/scripts-manifest" && jsondecode(output.config_json).compute.platform_prefix == "_platform"
    error_message = "a service's hosts need the manifest to verify the scripts they install, and the prefix they come from"
  }

  # An AMI ID in the contract would be copied and go stale; the parameter's name does not.
  assert {
    condition     = !strcontains(output.config_json, "ami-")
    error_message = "the contract must not contain an AMI ID"
  }
}

run "a_dedicated_environment_publishes_its_boundary_and_no_shared_fleet" {
  command = plan

  variables {
    hosting_model              = "dedicated"
    service_boundary_arn       = "arn:aws:iam::123456789012:policy/platform/core-service-boundary"
    deploy_bucket_name         = null
    fleet_update_document_name = null
    database_host              = null
    tiers = {
      private = {
        alb_security_group_id = "sg-0privalb"
        listener_arn          = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/core-private-alb-production/50dc6c495c0c9188/f2f7dc8efc522ab2"
      }
    }
  }

  assert {
    condition     = jsondecode(output.config_json).hosting_model == "dedicated" && jsondecode(output.config_json).service_boundary_arn == "arn:aws:iam::123456789012:policy/platform/core-service-boundary"
    error_message = "a dedicated environment must say so and publish its permissions boundary"
  }

  assert {
    condition     = jsondecode(output.config_json).buckets.deploy == null && jsondecode(output.config_json).fleet_update_document == null
    error_message = "a dedicated environment has no shared deploy bucket or fleet-update document"
  }

  assert {
    condition     = jsondecode(output.config_json).tiers.private.asg_name == null
    error_message = "a dedicated tier has no shared ASG"
  }
}

run "a_dedicated_tier_publishes_where_its_hosts_go" {
  command = plan

  variables {
    hosting_model = "dedicated"
    tiers = {
      private = {
        listener_arn          = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/x/1/2"
        alb_security_group_id = "sg-0alb"
        subnet_ids            = ["subnet-0a", "subnet-0b"]
      }
    }
  }

  assert {
    condition     = jsondecode(output.config_json).tiers.private.subnet_ids == ["subnet-0a", "subnet-0b"]
    error_message = "a service creating its own hosts learns the tier's subnets from the contract, rather than hard-coding them"
  }
}

run "a_managed_database_publishes_a_function_instead_of_a_document" {
  command = plan

  variables {
    database_provision_document_name = null
    database_provision_function_name = "core-production-postgres-provision"
  }

  assert {
    condition     = jsondecode(output.config_json).database.provision_function == "core-production-postgres-provision" && jsondecode(output.config_json).database.provision_document == null
    error_message = "a managed database is provisioned by invoking a function, not by sending a document"
  }
}

run "a_database_cannot_be_provisioned_two_ways_at_once" {
  command = plan

  variables {
    database_provision_document_name = "core-database-provision"
    database_provision_function_name = "core-production-postgres-provision"
  }

  expect_failures = [terraform_data.contract_invariants]
}

run "an_environment_without_a_database_publishes_null" {
  command = plan

  variables {
    database_host = null
  }

  assert {
    condition     = jsondecode(output.config_json).database.host == null
    error_message = "no database host means null, not an empty string"
  }
}

run "an_environment_without_tiers_is_allowed" {
  command = plan

  variables {
    tiers = {}
  }

  assert {
    condition     = length(jsondecode(output.config_json).tiers) == 0
    error_message = "an environment with no shared fleet publishes no tiers"
  }
}

run "an_unknown_tier_is_rejected" {
  command = plan

  variables {
    tiers = {
      edge = {
        security_group_id     = "sg-1"
        alb_security_group_id = "sg-2"
        asg_name              = "x"
        listener_arn          = "y"
      }
    }
  }

  expect_failures = [var.tiers]
}

run "an_oversized_contract_is_rejected" {
  command = plan

  variables {
    domain_name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  expect_failures = [terraform_data.contract_invariants]
}

# Run with: terraform init -backend=false && terraform test   (no AWS access needed)
#
# The data volume must survive changes around the host. Its availability zone
# comes from a subnet lookup inside terraform-aws-compute-storage; if anything
# makes Terraform put that lookup off until the apply, the zone is unknown at
# plan time and the volume is replaced, with every engine's data on it.
#
# The first run creates the module (mocked). The second changes the deploy
# bucket, which every platform script object, and the scripts manifest after
# them, depend on: the same pending change development's plan once showed.
#
# The volume sits two modules down, out of an assertion's reach, and a mocked
# provider never reports "forces replacement". scripts/ci/check-data-volume-plan.sh
# therefore runs this file with -verbose and fails if the second run's plan
# defers the subnet lookup or changes the volume.

mock_provider "aws" {
  # A subnet lookup answers the same zone on every run: a random one would move
  # the volume by itself.
  mock_data "aws_subnet" {
    defaults = { availability_zone = "af-south-1a" }
  }

  mock_data "aws_region" {
    defaults = { region = "af-south-1", name = "af-south-1" }
  }

  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }

  # The policies must be JSON objects; the mock's default is random text.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  # Resources that take another's ARN check that it is one.
  # A fixed ID, so the volume can be recognised from one run to the next.
  mock_resource "aws_ebs_volume" {
    defaults = { id = "vol-0123456789abcdef0" }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/acme-development-database-hub" }
  }

  mock_resource "aws_iam_policy" {
    defaults = { arn = "arn:aws:iam::123456789012:policy/acme-development-database-hub" }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:af-south-1:123456789012:secret:acme-database-hub-development-secret-vault-AbCdEf" }
  }

  mock_resource "aws_ssm_document" {
    defaults = { arn = "arn:aws:ssm:af-south-1:123456789012:document/acme-database-update" }
  }
}

mock_provider "random" {}

variables {
  project_name = "acme"
  environment  = "development"

  isolated_subnet_ids        = ["subnet-0123456789abcdef0"]
  isolated_security_group_id = "sg-0123456789abcdef0"
  ami_id                     = "ami-0123456789abcdef0"
  private_zone_id            = "Z0123456789ABCDEFGHIJ"
  private_domain             = "internal.example.org"

  deploy_bucket_name = "acme-development-deploy"
  deploy_bucket_arn  = "arn:aws:s3:::acme-development-deploy"

  db_enable_data_volume_mount = true
  db_data_volume_size         = 50

  connection_limits = {
    service_default    = 20
    person             = 5
    service_exceptions = {}
  }
}

run "the_host_is_built" {
  command = apply

  assert {
    condition     = module.database_host.data_volume_id == "vol-0123456789abcdef0"
    error_message = "the data volume is created"
  }
}

run "a_change_to_the_deploy_bucket_leaves_the_data_volume_in_place" {
  command = plan

  variables {
    deploy_bucket_name = "acme-development-deploy-2"
    deploy_bucket_arn  = "arn:aws:s3:::acme-development-deploy-2"
  }

  # The same volume, still there. What the plan does to it is read by
  # scripts/ci/check-data-volume-plan.sh.
  assert {
    condition     = module.database_host.data_volume_id == "vol-0123456789abcdef0"
    error_message = "the data volume must be the one already built, not replaced"
  }
}

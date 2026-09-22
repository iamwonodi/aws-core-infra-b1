################################################################################
# UBUNTU BASE AMI
#
# Builds the single golden Ubuntu AMI shared by both fleets below. Building
# it once here, rather than per-fleet, means both fleets always run the
# exact same base image and software set.
################################################################################

# The golden AMI every host in this environment runs, and the SSM parameter that
# publishes its ID. Extracted so that staging and production, which have no
# shared fleets, can still build one image for their services to use: one image
# per environment means a security fix is one rebuild, not one per service.
module "image" {
  source = "./image"

  project_name = var.project_name
  environment  = var.environment

  parent_image = local.parent_image

  enable_predefined_packages = var.enable_predefined_packages
  enable_docker              = var.enable_docker
  enable_aws_cli             = var.enable_aws_cli
  enable_python              = var.enable_python

  custom_build_commands    = var.custom_build_commands
  custom_validate_commands = var.custom_validate_commands

  component_version = var.component_version
  recipe_version    = var.recipe_version

  root_volume_size = var.root_volume_size
  root_volume_type = var.root_volume_type

  instance_types = var.ami_instance_types

  subnet_id          = var.internal_subnet_ids[0]
  security_group_ids = [var.internal_security_group_id]

  build_image   = var.build_image
  build_trigger = var.ami_build_trigger

  ami_description = var.ami_description

  enable_pipeline            = var.enable_pipeline
  pipeline_schedule          = var.pipeline_schedule
  enable_image_tests         = var.enable_image_tests
  image_test_timeout_minutes = var.image_test_timeout_minutes
}

################################################################################
# DEPLOY BUCKET AND PLATFORM SCRIPTS
#
# Extracted so that staging and production, which have no shared fleets, can
# still publish the scripts their services' own hosts install. Core owns those
# scripts for the same reason it owns the image: a fix to the deploy library is
# then one change, not one per service repository.
################################################################################

# The deploy library's fetch helper is inlined into every host's user data, so
# this module needs the library itself as well as the objects the deploy module
# publishes.
module "platform_scripts" {
  source = "../platform/host-scripts"
}

module "deploy" {
  source = "./deploy-bucket"

  project_name = var.project_name
  environment  = var.environment

  force_destroy = var.deploy_bucket_force_destroy

  fleet_update_script_path = local.update_script_path
}

# Runs the deploy. The only thing this document can do is run update.sh, so
# permission to send it (given to CI and to the secret-rotation rule) is not
# permission to run arbitrary commands on the fleet.
resource "aws_ssm_document" "fleet_update" {
  name            = local.fleet_update_document_name
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Runs the fleet deploy script (update.sh) on a fleet host."

    parameters = {
      jitterSeconds = {
        type           = "String"
        description    = "Maximum random delay in seconds before deploying, so hosts do not all restart a container at once. Use 0 for an immediate deploy."
        default        = "0"
        allowedPattern = "^[0-9]{1,3}$"
      }
    }

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "runFleetUpdate"
        inputs = {
          timeoutSeconds = "1800"
          runCommand     = ["JITTER_SECONDS={{ jitterSeconds }} ${local.application_root}/update.sh"]
        }
      }
    ]
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# Re-downloads the platform scripts on hosts that are already running, after
# they were changed. New hosts pick the change up at boot. The download is
# verified against the SSM manifest exactly as at boot.
resource "aws_ssm_document" "fleet_refresh_scripts" {
  name            = local.fleet_refresh_document_name
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Re-downloads and verifies the fleet platform scripts."

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "refreshScripts"
        inputs = {
          timeoutSeconds = "300"
          runCommand = concat(
            ["#!/usr/bin/env bash", "set -euo pipefail"],
            split("\n", module.platform_scripts.fetch_scripts_function),
            ["fetch_platform_scripts \"${module.deploy.scripts_manifest_parameter}\" \"${module.deploy.bucket_name}\" \"${local.aws_region}\" \"${local.application_root}\""]
          )
        }
      }
    ]
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# One read policy per tier: the shared scripts plus that tier's own prefix only.
resource "aws_iam_policy" "fleet_deploy_read" {
  for_each = local.fleet_tiers

  name        = "${var.project_name}-${var.environment}-fleet-deploy-read-${each.key}"
  description = "Read access for the ${each.key} fleet to the platform scripts and its own tier prefix of the deploy bucket."
  policy      = data.aws_iam_policy_document.fleet_deploy_read[each.key].json
}

resource "aws_iam_policy" "fleet_secrets_read" {
  name        = "${var.project_name}-${var.environment}-fleet-secrets-read"
  description = "Read access to this project's service secrets, resolved by update.sh at deploy time. The database hub secret is explicitly denied."
  policy      = data.aws_iam_policy_document.fleet_secrets_read.json
}

################################################################################
# PRIVATE-TIER FLEET
#
# Runs the frontend, the backend API (which forwards requests on to the
# internal tier), and the DB GUI client.
#
# Traffic path: CloudFront -> internal-facing ALB (private subnet) -> this
# fleet. No public DNS record exists on this fleet or on the ALB in front
# of it -- CloudFront's own domain is the only public entry point. See the
# edge domain module for why that ALB needs a CloudFront VPC origin rather
# than a plain custom origin.
################################################################################

module "private_profile" {
  source = "git::https://github.com/iamwonodi/terraform-aws-profile.git?ref=v1.1.0"

  project_name = var.project_name
  environment  = var.environment
  service_name = local.private_service_name

  enable_ssm_access      = true
  enable_ecr_read_access = true

  additional_policy_arns = [
    aws_iam_policy.fleet_deploy_read["private"].arn,
    aws_iam_policy.fleet_secrets_read.arn,
  ]
}

module "private_launch_template" {
  # The scripts and their manifest must exist before an instance can boot.
  depends_on = [module.deploy]

  source = "git::https://github.com/iamwonodi/terraform-aws-launch-template.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment
  service_name = local.private_service_name

  ami_id                    = module.image.ami_id
  iam_instance_profile_name = module.private_profile.instance_profile_name

  security_group_ids = [var.private_security_group_id]

  user_data = local.user_data[local.private_service_name]
}

module "private_autoscaling_group" {
  source = "git::https://github.com/iamwonodi/terraform-aws-autoscaling.git?ref=v3.0.0"

  project_name = var.project_name
  environment  = var.environment
  service_name = local.private_service_name

  launch_template_id      = module.private_launch_template.id
  launch_template_version = module.private_launch_template.latest_version

  subnet_ids = var.private_subnet_ids

  min_size         = var.private_fleet_min_size
  desired_capacity = var.private_fleet_desired_capacity
  max_size         = var.private_fleet_max_size

  # Each service attaches its own target group to this shared group from its own
  # repository. manage_traffic_sources stays false, so this module never reverts
  # those attachments -- which would otherwise take every service on the tier out
  # of the load balancer on the next core apply.
  #
  # health_check_type stays EC2 for the same reason: with ELB, one service failing
  # its health check would make the group replace a host every other service on
  # the tier is also running.
}

resource "aws_ssm_parameter" "private_autoscaling_group_arn" {
  name  = "/${var.project_name}/${local.private_service_name}/autoscaling-arn"
  type  = "String"
  value = module.private_autoscaling_group.arn
}

################################################################################
# INTERNAL-TIER FLEET
#
# Runs stateless internal applications (payment, notifications, and
# others). Reached only from the private tier's backend API -- never
# receives traffic directly from CloudFront or the internet.
################################################################################

module "internal_profile" {
  source = "git::https://github.com/iamwonodi/terraform-aws-profile.git?ref=v1.1.0"

  project_name = var.project_name
  environment  = var.environment
  service_name = local.internal_service_name

  enable_ssm_access      = true
  enable_ecr_read_access = true

  additional_policy_arns = [
    aws_iam_policy.fleet_deploy_read["internal"].arn,
    aws_iam_policy.fleet_secrets_read.arn,
  ]
}

module "internal_launch_template" {
  # The scripts and their manifest must exist before an instance can boot.
  depends_on = [module.deploy]

  source = "git::https://github.com/iamwonodi/terraform-aws-launch-template.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment
  service_name = local.internal_service_name

  ami_id                    = module.image.ami_id
  iam_instance_profile_name = module.internal_profile.instance_profile_name

  security_group_ids = [var.internal_security_group_id]

  user_data = local.user_data[local.internal_service_name]
}

module "internal_autoscaling_group" {
  source = "git::https://github.com/iamwonodi/terraform-aws-autoscaling.git?ref=v3.0.0"

  project_name = var.project_name
  environment  = var.environment
  service_name = local.internal_service_name

  launch_template_id      = module.internal_launch_template.id
  launch_template_version = module.internal_launch_template.latest_version

  subnet_ids = var.internal_subnet_ids

  min_size         = var.internal_fleet_min_size
  desired_capacity = var.internal_fleet_desired_capacity
  max_size         = var.internal_fleet_max_size

  # Shared group: see the note on the private fleet above.
}


resource "aws_ssm_parameter" "internal_autoscaling_group_arn" {
  name  = "/${var.project_name}/${local.internal_service_name}/autoscaling-arn"
  type  = "String"
  value = module.internal_autoscaling_group.arn
}


################################################################################
# SECRET ROTATION -> AUTOMATIC REDEPLOY
#
# Without this, a service team enabling automatic rotation on their own
# secret has no way to get that change actually picked up -- update.sh
# only ever runs at boot, or whenever someone manually triggers it again.
#
# Uses AWS's own recommended mechanism: the native "Secret Label Updated"
# event (delivered directly to EventBridge, not derived from CloudTrail,
# enabled by default for every secret -- confirmed against AWS's current
# documentation, not assumed), matched specifically on the AWSCURRENT
# label moving, which fires for both a manual secret update and an
# automatic rotation alike.
#
# This can't be scoped to "only this project's fleet secrets" via a real
# resource tag -- EventBridge event patterns only match the event's own
# JSON fields, not tags looked up separately on the resource that
# triggered it. True tag-based filtering would require an intermediate
# Lambda calling DescribeSecret to check tags before deciding whether to
# proceed -- a deliberate choice not to add that here. Instead, this is
# scoped by a NAMING CONVENTION: any secret intended to trigger a fleet
# redeploy must be named starting with
# "${var.project_name}-${var.environment}-fleet-" (e.g.
# "core-development-fleet-auth-db"). EventBridge's own prefix-match
# syntax on the event's "name" field (confirmed against AWS's current
# documentation) makes this filter real, not just a convention nobody
# enforces at the trigger level.
#
# Targets BOTH fleets by their shared Project/Environment tags (not a
# specific Service tag) since update.sh is safe to run on any instance
# regardless of whether that particular instance actually has the
# affected service deployed -- it just re-syncs and re-resolves
# everything, and is a harmless no-op for services not present there.
################################################################################

resource "aws_cloudwatch_event_rule" "fleet_secret_rotated" {
  name        = "${var.project_name}-${var.environment}-fleet-secret-rotated"
  description = "Matches AWSCURRENT label changes (manual update or automatic rotation) on any secret named ${var.project_name}-${var.environment}-fleet-*."

  event_pattern = jsonencode({
    source      = ["aws.secretsmanager"]
    detail-type = ["Secret Label Updated"]
    detail = {
      labelUpdated = ["AWSCURRENT"]
      name = [
        { prefix = "${var.project_name}-${var.environment}-fleet-" }
      ]
    }
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}


resource "aws_iam_role" "fleet_secret_rotated" {
  name               = "${var.project_name}-${var.environment}-fleet-secret-rotated"
  assume_role_policy = data.aws_iam_policy_document.fleet_secret_rotated_assume_role.json

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "fleet_secret_rotated_send_command" {
  name   = "send-command"
  role   = aws_iam_role.fleet_secret_rotated.id
  policy = data.aws_iam_policy_document.fleet_secret_rotated_send_command.json
}

resource "aws_cloudwatch_event_target" "fleet_secret_rotated" {
  rule     = aws_cloudwatch_event_rule.fleet_secret_rotated.name
  arn      = aws_ssm_document.fleet_update.arn
  role_arn = aws_iam_role.fleet_secret_rotated.arn

  run_command_targets {
    key    = "tag:Project"
    values = [var.project_name]
  }

  run_command_targets {
    key    = "tag:Environment"
    values = [var.environment]
  }

  # Only the fleet hosts. The database host carries the same Project and
  # Environment tags but has no fleet update script.
  run_command_targets {
    key    = "tag:Service"
    values = [local.private_service_name, local.internal_service_name]
  }

  # Rotation reaches every host at the same moment; the jitter staggers the
  # container restarts so a service is not down everywhere at once.
  input = jsonencode({
    jitterSeconds = ["60"]
  })
}

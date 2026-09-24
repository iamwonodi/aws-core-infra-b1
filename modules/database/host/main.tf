########################################################################################
# CORE SECRET VAULT
#
# Stores the database's administrator login details. The random_password
# resource generates the actual secret value; nothing about it is
# rendered into any user-data script or template -- only its ARN
# (core_root_secret_arn, in locals.tf) is, so the running instance can
# fetch the real secret from Secrets Manager at boot rather than the
# secret ever appearing in rendered configuration.
########################################################################################

resource "random_password" "db_password" {
  length           = 32
  special          = true
  override_special = local.specials
}

module "secrets_vault" {
  source = "git::https://github.com/iamwonodi/terraform-aws-secrets-vault.git?ref=v1.0.0"

  project_name = var.project_name
  environment  = var.environment
  service_name = local.database_service_name

  secret_kv_pairs = {
    username      = local.db_username
    root_password = random_password.db_password.result
  }
}

########################################################################################
# THE CENTRAL CONSOLIDATED DATABASE HUB
########################################################################################

################################################################################
# PLATFORM SCRIPTS AND THEIR CHECKSUM MANIFEST
#
# The shared deploy library is uploaded by the compute module, which owns the
# deploy bucket; this module uploads the database scripts beside it and
# publishes one manifest covering all three.
################################################################################

module "platform_scripts" {
  source = "../../platform/host-scripts"
}

resource "aws_s3_object" "database_update" {
  bucket = var.deploy_bucket_name
  key    = local.database_update_key
  source = local.update_script_path
  etag   = filemd5(local.update_script_path)
}

resource "aws_s3_object" "database_provision" {
  bucket = var.deploy_bucket_name
  key    = local.database_provision_key
  source = local.provision_script_path
  etag   = filemd5(local.provision_script_path)
}

resource "aws_s3_object" "database_provision_service" {
  bucket = var.deploy_bucket_name
  key    = local.database_provision_service_key
  source = local.provision_service_script_path
  etag   = filemd5(local.provision_service_script_path)
}

resource "aws_s3_object" "database_provision_people" {
  bucket = var.deploy_bucket_name
  key    = local.database_provision_people_key
  source = local.provision_people_script_path
  etag   = filemd5(local.provision_people_script_path)
}

# Core's per-engine provisioning scripts, fetched by the host exactly like the
# rest of its platform scripts and verified against the same manifest.
resource "aws_s3_object" "database_provisioning_scripts" {
  for_each = local.provisioning_scripts

  bucket = var.deploy_bucket_name
  key    = each.key
  source = each.value
  etag   = filemd5(each.value)
}

resource "aws_ssm_parameter" "database_scripts_manifest" {
  name        = local.scripts_manifest_parameter
  description = "SHA-256 of every platform script the database host installs, keyed by S3 object."
  type        = "String"
  value       = jsonencode(local.scripts_manifest)

  # The objects must exist before a manifest promises their checksums.
  depends_on = [
    aws_s3_object.database_update,
    aws_s3_object.database_provision,
    aws_s3_object.database_provision_service,
    aws_s3_object.database_provision_people,
    aws_s3_object.database_provisioning_scripts,
  ]
}

# Runs the database deploy. The only thing this document can do is run
# update.sh, so permission to send it (given to the platforms pipeline) is not
# permission to run arbitrary commands on the database host.
resource "aws_ssm_document" "database_update" {
  name            = local.update_document_name
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Runs the database deploy script (update.sh) on the database host."

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "runDatabaseUpdate"
        inputs = {
          timeoutSeconds = "1800"
          runCommand     = ["${local.database_workspace}/update.sh"]
        }
      }
    ]
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# Creates one service's database and user. A service's infrastructure repository
# publishes its request to the deploy bucket and sends this document; permission
# to send it is not permission to run arbitrary commands on the database host.
#
# The service name is a document parameter, and its pattern is enforced HERE as
# well as in the script: allowedPattern is what stops anything but a service name
# reaching the host at all. IAM cannot condition ssm:SendCommand on a parameter's
# value, so any service's infrastructure role that may send this document may
# name another service -- which re-runs that service's own provisioning from its
# own published request, and is therefore harmless.
resource "aws_ssm_document" "database_provision" {
  name            = local.provision_document_name
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Creates a service's database and user on the database host."

    parameters = {
      serviceName = {
        type           = "String"
        description    = "The service to provision."
        allowedPattern = "^[a-z][a-z0-9-]{1,20}[a-z0-9]$"
      }
    }

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "provisionService"
        inputs = {
          timeoutSeconds = "600"
          runCommand     = ["${local.database_workspace}/provision-service.sh '{{ serviceName }}'"]
        }
      }
    ]
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# Brings the team's logins (agent_<name>, core's people list) on every running
# engine in line with the people secret. Core's apply sends it after applying;
# permission to send it is not permission to run arbitrary commands on the
# database host. It takes no parameters: the only input is the people secret.
resource "aws_ssm_document" "database_provision_people" {
  name            = local.provision_people_document_name
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Brings the team's database logins on the database host in line with core's people secret."

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "provisionPeople"
        inputs = {
          timeoutSeconds = "600"
          runCommand     = ["${local.database_workspace}/provision-people.sh"]
        }
      }
    ]
  })

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# Re-downloads the platform scripts on the running host after they were
# changed, verifying them against the SSM manifest exactly as at boot.
resource "aws_ssm_document" "database_refresh_scripts" {
  name            = local.refresh_document_name
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Re-downloads and verifies the database host's platform scripts."

    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "refreshScripts"
        inputs = {
          timeoutSeconds = "300"
          runCommand = concat(
            ["#!/usr/bin/env bash", "set -euo pipefail"],
            split("\n", module.platform_scripts.fetch_scripts_function),
            ["fetch_platform_scripts \"${local.scripts_manifest_parameter}\" \"${var.deploy_bucket_name}\" \"${local.aws_region}\" \"${local.database_workspace}\""]
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

resource "aws_iam_policy" "database_platform_read" {
  name        = "${var.project_name}-${var.environment}-database-platform-read"
  description = "Lets the database host read its scripts, the platforms team's engine definitions and the secrets it resolves."
  policy      = data.aws_iam_policy_document.database_platform_read.json
}

module "database_profile" {
  source = "git::https://github.com/iamwonodi/terraform-aws-profile.git?ref=v1.1.1"

  project_name = var.project_name
  environment  = var.environment
  service_name = local.database_service_name

  enable_ssm_access           = true
  enable_ecr_read_access      = var.db_enable_ecr_read_access
  enable_route53_write_access = var.db_enable_route53_write_access
  hosted_zone_id              = var.private_zone_id

  additional_policy_arns = [aws_iam_policy.database_platform_read.arn]
}

module "database_host" {
  source = "git::https://github.com/iamwonodi/terraform-aws-compute-storage.git?ref=v1.1.0"

  project_name = var.project_name
  environment  = var.environment
  service_name = local.database_service_name

  subnet_id         = var.isolated_subnet_ids[0]
  security_group_id = var.isolated_security_group_id

  ami_id                = var.ami_id
  instance_type         = var.db_instance_type
  instance_profile_name = module.database_profile.instance_profile_name
  root_volume_size      = var.db_root_volume_size

  associate_public_ip_address = var.db_associate_public_ip_address

  enable_data_volume_mount = var.db_enable_data_volume_mount
  data_volume_device       = var.db_data_volume_device
  data_volume_size         = var.db_data_volume_size

  user_data = local.database_user_data

  # The scripts and their manifest must exist before the host can boot.
  depends_on = [aws_ssm_parameter.database_scripts_manifest]
}

resource "aws_ssm_parameter" "database_host_instance_id" {
  name  = "/${var.project_name}/${local.database_service_name}/instance-id"
  type  = "String"
  value = module.database_host.instance_id
}

########################################################################################
# EC2 AUTO-RECOVERY
#
# The database is a single stateful instance, not a fleet -- an Auto
# Scaling Group is the wrong recovery mechanism here specifically because
# the data volume is a separately Terraform-managed EBS resource attached
# by instance_id. An ASG-driven replacement instance would need that
# volume reattached by something outside Terraform's own apply cycle,
# since ASG replacement happens on AWS's own schedule, not Terraform's.
#
# EC2 auto-recovery is the correct fit instead: on a system status check
# failure (the underlying hardware is impaired), AWS migrates this exact
# instance to new hardware, preserving the same instance ID, private IP,
# and attached EBS volumes -- confirmed directly against AWS's own
# documentation. Concretely, that means: no DNS re-registration needed
# (the private IP doesn't change, so the record below stays correct), no
# volume reattachment needed (stays attached automatically), and no
# script changes needed at all (docker-compose.yml already sets
# "restart: unless-stopped", so Docker brings the database containers
# back up on its own once the instance reboots).
#
# This does not cover every possible failure: it only triggers on a
# system-level status check failure (impaired underlying hardware), not
# an OS-level hang that doesn't trip that check, and not an accidental
# manual termination (a terminated instance cannot be recovered).
#
# Cost: this is a single standard-resolution alarm on a built-in EC2
# metric. The first 10 standard alarms per account/region are free, and
# built-in AWS service metrics (unlike custom application metrics) never
# have their own per-metric charge. The 300-second period below matches
# EC2's free "basic monitoring" reporting interval, so this alarm incurs
# no cost at all under typical use -- enabling "detailed monitoring"
# (1-minute) would allow a shorter period for faster detection, at
# roughly $2.10/instance/month, but is not required for this alarm to
# function correctly.
########################################################################################

resource "aws_cloudwatch_metric_alarm" "database_auto_recovery" {
  alarm_name        = "${var.project_name}-${var.environment}-${local.database_service_name}-auto-recovery"
  alarm_description = "Triggers EC2 auto-recovery when the database host's underlying hardware fails a system status check."

  namespace   = "AWS/EC2"
  metric_name = "StatusCheckFailed_System"
  statistic   = "Maximum"

  period              = 300
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"

  dimensions = {
    InstanceId = module.database_host.instance_id
  }

  alarm_actions = [
    "arn:aws:automate:${data.aws_region.current.region}:ec2:recover"
  ]

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

########################################################################################
# PRIVATE DNS RECORD
#
# Terraform-managed, not self-registered by the instance at boot. This is
# correct precisely because of the auto-recovery alarm above: the private
# IP stays stable across every realistic failure/replacement scenario
# (auto-recovery preserves it; a Terraform-triggered replacement updates
# this record in the same apply, since it depends on
# module.database_host.private_ip). A static record is simpler, doesn't need
# any IAM permission on the instance itself (see
# db_enable_route53_write_access in variables.tf), and is correct the
# moment "terraform apply" finishes -- before the instance has even
# booted -- rather than partway through bootstrap.sh's own execution.
########################################################################################

module "database_private_dns_record" {
  count = var.db_enable_private_dns_registration ? 1 : 0

  source = "git::https://github.com/iamwonodi/terraform-aws-route53-record.git?ref=v1.0.0"

  records = {
    database = {
      zone_id = var.private_zone_id
      name    = local.db_private_dns_record_name
      type    = "A"
      ttl     = 60

      records = [module.database_host.private_ip]
    }
  }
}





########################################################################################
# AUTOMATED BACKUPS
#
# Daily EBS snapshots of the persistent data volume via DLM (Data
# Lifecycle Manager), not AWS Backup -- deliberately the lighter tool.
# AWS Backup's extra features (cross-region copy, centralized
# multi-account policies, legal-hold vaults) are aimed at production
# compliance and DR needs this development environment doesn't have.
#
# This backs up the VOLUME at the block level -- crash-consistent, not
# application-consistent (equivalent to recovering from a sudden power
# loss, not a clean shutdown). Modern journaling engines (InnoDB,
# Postgres WAL, WiredTiger) generally recover fine from that, but it is
# a real distinction from a coordinated database-level backup.
#
# This also cannot restore just one service team's data in isolation --
# a restore brings back the whole volume, every engine and every team
# together, since multiple teams' databases share this one host and
# volume. If that granular, per-team restore need becomes real, the
# next step is per-team logical dumps (mysqldump/pg_dump/mongodump) to
# S3 alongside this, not a replacement for it.
########################################################################################


resource "aws_iam_role" "dlm_backup" {
  count = (var.db_enable_data_volume_mount && var.db_enable_automated_backups) ? 1 : 0

  name               = "${var.project_name}-${var.environment}-${local.database_service_name}-dlm-backup"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume_role[0].json

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# AWS-managed policy scoped specifically to what DLM's own service needs
# to create/copy/delete snapshots -- not a hand-written policy document,
# since this exact managed policy is what AWS itself documents and
# maintains for this purpose.
resource "aws_iam_role_policy_attachment" "dlm_backup" {
  count = (var.db_enable_data_volume_mount && var.db_enable_automated_backups) ? 1 : 0

  role       = aws_iam_role.dlm_backup[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "database_backup" {
  count = (var.db_enable_data_volume_mount && var.db_enable_automated_backups) ? 1 : 0

  # DLM accepts only letters, digits, spaces, underscores and hyphens here, so no
  # punctuation such as a full stop: the provider rejects it at validate time.
  description        = "Daily snapshots of the ${local.database_service_name} persistent data volume"
  execution_role_arn = aws_iam_role.dlm_backup[0].arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    # Targets the data volume by its Name tag specifically -- see
    # locals.tf for why this is computed rather than read from a tag
    # pass-through that doesn't currently exist on compute-storage.
    target_tags = {
      Name = local.data_volume_name
    }

    schedule {
      name = "daily-snapshots"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["03:00"]
      }

      retain_rule {
        count = var.db_backup_retention_days
      }

      tags_to_add = {
        SnapshotType = "automated-dlm"
      }

      copy_tags = true
    }
  }

  tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

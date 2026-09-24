data "aws_caller_identity" "current" {}

# .region, not the deprecated .name -- AWS provider 6.0.0 deprecated
# aws_region's "name" attribute in favor of "region". Same fix already
# applied in the database domain module.
data "aws_region" "current" {}



# What each tier's hosts may read from the deploy bucket: the shared scripts,
# and ONLY their own tier's prefix. The private and internal fleets run
# different applications, so neither can read the other's service files (which
# include secret ARNs).
data "aws_iam_policy_document" "fleet_deploy_read" {
  for_each = local.fleet_tiers

  statement {
    sid     = "ReadPlatformScriptsAndOwnTier"
    actions = ["s3:GetObject"]

    resources = [
      "${module.deploy.bucket_arn}/_platform/lib/*",
      "${module.deploy.bucket_arn}/_platform/fleet/*",
      "${module.deploy.bucket_arn}/${each.key}/*",
    ]
  }

  statement {
    sid       = "ListOwnTier"
    actions   = ["s3:ListBucket"]
    resources = [module.deploy.bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${each.key}", "${each.key}/*"]
    }
  }

  statement {
    sid       = "ReadScriptsManifest"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${local.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${module.deploy.scripts_manifest_parameter}"]
  }
}

# Secrets the fleet resolves at deploy time. Scoped to the vault module's
# naming scheme, <project>-<service>-<environment>-secret-vault, so a host can
# only read this project's and environment's service secrets. Secrets Manager
# appends a random six-character suffix to every ARN, hence the trailing "-*".
#
# The database hub's own secret follows the same scheme, so it is denied
# explicitly: it holds the database administrator credential, which only the
# database host may read. An explicit Deny always beats an Allow.
data "aws_iam_policy_document" "fleet_secrets_read" {
  statement {
    sid     = "ReadServiceSecrets"
    actions = ["secretsmanager:GetSecretValue"]

    resources = [
      "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}-*-${var.environment}-secret-vault-*",
    ]
  }

  # The platform's own database secrets -- the hub's administrator, the people's
  # passwords -- all match the pattern above too. Service names beginning with
  # "database-" are reserved (service-roles), so every secret named
  # <project>-database-*-<environment>-... is the platform's, and denied.
  statement {
    sid     = "NeverReadThePlatformDatabaseSecrets"
    effect  = "Deny"
    actions = ["secretsmanager:GetSecretValue"]

    resources = [
      "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}-${var.database_service_name}-${var.environment}-secret-vault-*",
      "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}-database-*-${var.environment}-secret-vault-*",
    ]
  }
}

data "aws_iam_policy_document" "fleet_secret_rotated_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
  }
}


data "aws_iam_policy_document" "fleet_secret_rotated_send_command" {
  statement {
    sid       = "RunTheFleetUpdateDocumentOnly"
    actions   = ["ssm:SendCommand"]
    resources = [aws_ssm_document.fleet_update.arn]
  }

  statement {
    sid       = "OnlyOnThisProjectsInstances"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ec2:${local.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Project"
      values   = [var.project_name]
    }
  }
}

# Canonical publishes the current Ubuntu 24.04 LTS AMI ID in each Region as a
# public SSM parameter, so no AMI ID needs to be looked up or kept up to date by
# hand. Read only when no explicit ubuntu_parent_image is given. The amd64 image
# is right for the x86 instance types the fleets use; a Graviton build would need
# the arm64 parameter.
data "aws_ssm_parameter" "ubuntu_parent_image" {
  count = var.ubuntu_parent_image == null ? 1 : 0

  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

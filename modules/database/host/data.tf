data "aws_caller_identity" "current" {}

# .region, not the deprecated .name -- AWS provider 6.0.0 deprecated
# aws_region's "name" attribute in favor of "region". Using .region here
# avoids the deprecation warning (and eventual breakage) that .name would
# otherwise produce on every plan.
data "aws_region" "current" {}



data "aws_iam_policy_document" "dlm_assume_role" {
  count = (var.db_enable_data_volume_mount && var.db_enable_automated_backups) ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

# What the database host may read. Engines are defined by the platforms team in
# the deploy bucket under database/, and the host's own scripts sit under
# _platform/. It may also read the vault secrets: the database hub's own
# administrator credential (referenced from each engine's .env) and the
# service-owned secrets that provision.sh reads when it creates a service's
# database and user.
data "aws_iam_policy_document" "database_platform_read" {
  statement {
    sid     = "ReadScriptsAndEngineDefinitions"
    actions = ["s3:GetObject"]

    resources = [
      "${var.deploy_bucket_arn}/_platform/lib/*",
      "${var.deploy_bucket_arn}/_platform/database/*",
      "${var.deploy_bucket_arn}/database/*",

      # The provisioning requests services publish: config.json and, optionally,
      # their own extra.sql.
      "${var.deploy_bucket_arn}/provisioning/*",
    ]
  }

  statement {
    sid       = "ListEngineDefinitions"
    actions   = ["s3:ListBucket"]
    resources = [var.deploy_bucket_arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["database", "database/*"]
    }
  }

  statement {
    sid       = "ReadScriptsManifest"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${local.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.scripts_manifest_parameter}"]
  }

  statement {
    sid       = "ReadConnectionLimits"
    actions   = ["ssm:GetParameter"]
    resources = ["arn:aws:ssm:${local.aws_region}:${data.aws_caller_identity.current.account_id}:parameter${local.connection_limits_parameter}"]
  }

  statement {
    sid     = "ReadVaultSecrets"
    actions = ["secretsmanager:GetSecretValue"]

    resources = [
      "arn:aws:secretsmanager:${local.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${var.project_name}-*-${var.environment}-secret-vault-*",
    ]
  }
}

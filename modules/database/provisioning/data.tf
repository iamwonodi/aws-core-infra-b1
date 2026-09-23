data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# ------------------------------------------------------------------------------
# The function's package
#
# The driver is committed beside the handler (see lambda/vendor/README.md): the
# Lambda runtimes carry no database driver, and a compiled one would have to
# match the runtime's architecture, so a pure-Python one is vendored.
# ------------------------------------------------------------------------------

data "archive_file" "provision" {
  type        = "zip"
  source_dir  = "${path.module}/lambda"
  output_path = "${path.module}/.terraform-build/provision.zip"

  excludes = ["tests", "vendor/README.md", "certificates/README.md"]
}

# ------------------------------------------------------------------------------
# Permissions
# ------------------------------------------------------------------------------

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "this" {
  # Running a function in a VPC means creating and deleting network interfaces.
  # AWS does not scope these to one VPC or subnet.
  statement {
    sid = "NetworkInterfaces"

    actions = [
      "ec2:CreateNetworkInterface",
      "ec2:DeleteNetworkInterface",
      "ec2:DescribeNetworkInterfaces",
    ]

    resources = ["*"]
  }

  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  # The administrator credential, and every service's own secret under core's
  # naming convention. Nothing else in Secrets Manager.
  statement {
    sid     = "Secrets"
    actions = ["secretsmanager:GetSecretValue"]

    resources = [
      var.admin_secret_arn,
      "arn:aws:secretsmanager:${local.aws_region}:${local.account_id}:secret:${replace(local.service_secret_pattern, "{service}", "*")}-*",
    ]
  }
}

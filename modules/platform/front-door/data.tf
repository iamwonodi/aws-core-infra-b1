# ------------------------------------------------------------------------------
# The function's package: the handler alone. boto3 is in the Lambda runtime.
# ------------------------------------------------------------------------------

data "archive_file" "function" {
  type        = "zip"
  source_file = "${path.module}/lambda/front_door.py"
  output_path = "${path.module}/.terraform-build/front-door.zip"
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ------------------------------------------------------------------------------
# Permissions
# ------------------------------------------------------------------------------

# What it reads and what it changes, and nothing more: the declarations, and
# the users of this one pool.
data "aws_iam_policy_document" "function" {
  statement {
    sid       = "Logs"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this.arn}:*"]
  }

  statement {
    sid       = "ListDeclarations"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::${var.deploy_bucket_name}"]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.declaration_prefix}*"]
    }
  }

  statement {
    sid       = "ReadDeclarations"
    actions   = ["s3:GetObject"]
    resources = ["arn:aws:s3:::${var.deploy_bucket_name}/${local.declaration_prefix}*"]
  }

  statement {
    sid       = "ManageThisPoolsUsers"
    actions   = ["cognito-idp:ListUsers", "cognito-idp:AdminCreateUser", "cognito-idp:AdminDeleteUser"]
    resources = [aws_cognito_user_pool.this.arn]
  }
}


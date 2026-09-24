# ------------------------------------------------------------------------------
# FRONT DOOR
#
# The Cognito sign-in the team tools' web addresses sit behind (development and
# staging; production's tools are reached only through a private tunnel), and
# the function that decides who is in it.
#
# WHO IS IN IT. Everyone declared, and no one else. Declarations are JSON files
# in the deploy bucket, { "emails": [ ... ] }:
#
#   front-door/<service>.json   a service's agents; each service's role may write
#                               its own file and no other
#   front-door/_platform.json   core's platform list, written here ("_" can
#                               never begin a service's name)
#
# Whenever a declaration is created, changed or deleted, S3 invokes the function,
# which reads EVERY declaration and makes the pool's users match their union:
# one sign-in per email, however many services declare it, removed once none
# does. If any declaration cannot be read or is malformed it changes nothing,
# rather than act on part of the picture. A user added to the pool by hand is
# removed on the next run: the declarations are the only way in.
#
# No service role touches Cognito: permissions on a user pool cannot be limited
# to some of its users, so a role that could add its own people could remove
# everyone else's.
#
# WHAT IT LEAVES TO THE TOOLS REPOSITORY: the app client and its managed login
# style. They carry the tools' own web addresses.
# ------------------------------------------------------------------------------

locals {
  function_name      = "${var.project_name}-${var.environment}-front-door"
  declaration_prefix = "front-door/"
  platform_key       = "${local.declaration_prefix}_platform.json"
}

resource "aws_cognito_user_pool" "this" {
  name = "${var.project_name}-${var.environment}-team"

  # Essentials: its managed login walks a new user through setting up their
  # authenticator app. Free up to 10,000 monthly active users per account (the
  # Plus tier has no free allowance).
  user_pool_tier = "ESSENTIALS"

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  admin_create_user_config {
    allow_admin_create_user_only = true
  }

  # An authenticator app, always. No SMS (it costs per message) and no email
  # codes (the same inbox as a password reset would be one factor, not two).
  mfa_configuration = "ON"

  software_token_mfa_configuration {
    enabled = true
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Cognito's own sender: free, no domain to verify, about 50 messages a day,
  # from no-reply@verificationemail.com. Enough for a team's invitations.
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  deletion_protection = "ACTIVE"

  tags = var.tags
}

# The sign-in pages. Prefixes are shared by every account in the Region, so the
# account ID makes this one unique. Version 2 is managed login, which needs a
# style per app client: the tools repository creates it with its client.
resource "aws_cognito_user_pool_domain" "this" {
  domain                = "${var.project_name}-${var.environment}-team-${var.account_id}"
  user_pool_id          = aws_cognito_user_pool.this.id
  managed_login_version = 2
}

# ------------------------------------------------------------------------------
# Declarations
# ------------------------------------------------------------------------------

resource "aws_s3_object" "platform_declaration" {
  bucket       = var.deploy_bucket_name
  key          = local.platform_key
  content      = jsonencode({ emails = sort(distinct([for email in var.platform_emails : lower(email)])) })
  content_type = "application/json"

  # The function reads every declaration when this one changes, so it must exist
  # before the first object event can reach it.
  depends_on = [aws_s3_bucket_notification.declarations]
}

# ------------------------------------------------------------------------------
# The function
# ------------------------------------------------------------------------------

resource "aws_iam_role" "function" {
  name               = local.function_name
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "function" {
  name   = "front-door"
  role   = aws_iam_role.function.id
  policy = data.aws_iam_policy_document.function.json
}

resource "aws_cloudwatch_log_group" "this" {
  name              = "/aws/lambda/${local.function_name}"
  retention_in_days = 30
  tags              = var.tags
}

# Outside any VPC: it talks to S3 and Cognito only, never to a database.
resource "aws_lambda_function" "this" {
  function_name    = local.function_name
  description      = "Makes the team tools' sign-ins match the front-door declarations."
  role             = aws_iam_role.function.arn
  runtime          = "python3.14"
  handler          = "front_door.handler"
  filename         = data.archive_file.function.output_path
  source_code_hash = data.archive_file.function.output_base64sha256
  timeout          = 60
  memory_size      = 128

  environment {
    variables = {
      DECLARATIONS_BUCKET = var.deploy_bucket_name
      DECLARATIONS_PREFIX = local.declaration_prefix
      PLATFORM_KEY        = local.platform_key
      USER_POOL_ID        = aws_cognito_user_pool.this.id
    }
  }

  tags = var.tags

  depends_on = [aws_iam_role_policy.function, aws_cloudwatch_log_group.this]
}

resource "aws_lambda_permission" "s3" {
  statement_id   = "DeclarationChanged"
  action         = "lambda:InvokeFunction"
  function_name  = aws_lambda_function.this.function_name
  principal      = "s3.amazonaws.com"
  source_arn     = "arn:aws:s3:::${var.deploy_bucket_name}"
  source_account = var.account_id
}

# S3 keeps ONE notification configuration per bucket, and this resource owns
# the deploy bucket's. Anything else that needs events from the bucket must be
# added here, not in a second aws_s3_bucket_notification.
resource "aws_s3_bucket_notification" "declarations" {
  bucket = var.deploy_bucket_name

  lambda_function {
    lambda_function_arn = aws_lambda_function.this.arn
    events              = ["s3:ObjectCreated:*", "s3:ObjectRemoved:*"]
    filter_prefix       = local.declaration_prefix
    filter_suffix       = ".json"
  }

  depends_on = [aws_lambda_permission.s3]
}

# Run with: terraform init -backend=false && terraform test   (no AWS access needed)
#
# Assertions use only values known at plan time: Terraform leaves computed
# attributes (IDs, ARNs) unknown in a planned test.

mock_provider "aws" {
  # The policies must be JSON objects; the mock's default is random text.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }

  # Resources that take another's ARN check that it is one.
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/acme-development-front-door" }
  }

  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:af-south-1:123456789012:function:acme-development-front-door" }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:af-south-1:123456789012:log-group:/aws/lambda/acme-development-front-door" }
  }

  mock_resource "aws_cognito_user_pool" {
    defaults = { arn = "arn:aws:cognito-idp:af-south-1:123456789012:userpool/af-south-1_Abc" }
  }
}

mock_provider "archive" {}

variables {
  project_name       = "acme"
  environment        = "development"
  account_id         = "123456789012"
  deploy_bucket_name = "acme-development-deploy"
  platform_emails    = ["Devigma@Example.org", "ada@example.org", "devigma@example.org"]
}

run "the_platform_declares_its_list" {
  command = plan

  assert {
    condition     = aws_s3_object.platform_declaration.key == "front-door/_platform.json"
    error_message = "core's own declaration, named so no service can take the name"
  }

  assert {
    condition     = jsondecode(aws_s3_object.platform_declaration.content) == { emails = ["ada@example.org", "devigma@example.org"] }
    error_message = "the platform list's emails, in lower case, each once"
  }
}

run "only_declarations_invoke_the_function" {
  command = plan

  assert {
    condition     = one(aws_s3_bucket_notification.declarations.lambda_function).filter_prefix == "front-door/" && one(aws_s3_bucket_notification.declarations.lambda_function).filter_suffix == ".json"
    error_message = "only a declaration's change invokes the function"
  }

  assert {
    condition     = toset(one(aws_s3_bucket_notification.declarations.lambda_function).events) == toset(["s3:ObjectCreated:*", "s3:ObjectRemoved:*"])
    error_message = "a declaration written, changed or deleted"
  }

  assert {
    condition     = aws_lambda_permission.s3.principal == "s3.amazonaws.com" && aws_lambda_permission.s3.source_arn == "arn:aws:s3:::acme-development-deploy" && aws_lambda_permission.s3.source_account == "123456789012"
    error_message = "only this account's deploy bucket may invoke it"
  }
}

run "the_function_reaches_only_what_it_needs" {
  command = plan

  assert {
    condition     = length(aws_lambda_function.this.vpc_config) == 0
    error_message = "outside any VPC: it talks to S3 and Cognito, never a database"
  }

  assert {
    condition     = aws_lambda_function.this.environment[0].variables.DECLARATIONS_PREFIX == "front-door/" && aws_lambda_function.this.environment[0].variables.PLATFORM_KEY == "front-door/_platform.json"
    error_message = "it reads the declarations and requires the platform's among them"
  }

  assert {
    condition     = aws_lambda_function.this.function_name == "acme-development-front-door" && aws_lambda_function.this.runtime == "python3.14"
    error_message = "named for the environment, on the platform's runtime"
  }
}

run "the_pool_is_the_front_door_decided_before" {
  command = plan

  assert {
    condition     = aws_cognito_user_pool.this.user_pool_tier == "ESSENTIALS" && aws_cognito_user_pool.this.mfa_configuration == "ON" && aws_cognito_user_pool.this.software_token_mfa_configuration[0].enabled
    error_message = "Essentials, with an authenticator app always required"
  }

  assert {
    condition     = aws_cognito_user_pool.this.admin_create_user_config[0].allow_admin_create_user_only && aws_cognito_user_pool.this.deletion_protection == "ACTIVE"
    error_message = "no self sign-up, and the pool cannot be deleted by accident"
  }

  assert {
    condition     = aws_cognito_user_pool_domain.this.domain == "acme-development-team-123456789012" && aws_cognito_user_pool_domain.this.managed_login_version == 2
    error_message = "a sign-in domain unique to the account, on managed login"
  }

  assert {
    condition     = output.front_door.declaration_prefix == "front-door/"
    error_message = "services learn where to declare"
  }
}

run "an_invalid_platform_email_is_refused" {
  command = plan

  variables {
    platform_emails = ["not-an-email"]
  }

  expect_failures = [var.platform_emails]
}

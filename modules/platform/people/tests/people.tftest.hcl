# Run with: terraform init -backend=false && terraform test   (no AWS access needed)
#
# Assertions use only values known at plan time: Terraform leaves computed
# attributes (IDs, ARNs) unknown in a planned test.

mock_provider "aws" {}
mock_provider "random" {}

variables {
  project_name = "acme"
  environment  = "development"
  account_id   = "123456789012"

  people = {
    ada   = { email = "Ada@Example.org", access = "write" }
    tunde = { email = "tunde@example.org", access = "read" }
  }

  front_door = true
}

run "each_person_gets_a_platform_login_and_a_sign_in" {
  command = plan

  assert {
    condition     = output.usernames == { ada = "platform.ada", tunde = "platform.tunde" }
    error_message = "each person's database login is platform.<name>"
  }

  assert {
    condition     = output.access == { "platform.ada" = "write", "platform.tunde" = "read" }
    error_message = "each login carries its person's access level"
  }

  assert {
    condition     = length(random_password.person) == 2 && random_password.person["ada"].length == 40 && random_password.person["ada"].override_special == "-_."
    error_message = "one password per person, in the platform's alphabet"
  }

  assert {
    condition     = aws_secretsmanager_secret.this.name == "acme-database-people-development-secret-vault"
    error_message = "one secret for the environment, named in the platform's database family"
  }

  assert {
    condition     = aws_cognito_user.person["ada"].username == "ada@example.org" && aws_cognito_user.person["ada"].attributes.email_verified == "true"
    error_message = "a person signs in with their email, stored in lower case"
  }
}

run "the_front_door_requires_an_authenticator_and_an_invitation" {
  command = plan

  assert {
    condition     = aws_cognito_user_pool.this[0].user_pool_tier == "ESSENTIALS" && aws_cognito_user_pool.this[0].mfa_configuration == "ON"
    error_message = "Essentials (its managed login sets up the authenticator), with MFA always on"
  }

  assert {
    condition     = aws_cognito_user_pool.this[0].software_token_mfa_configuration[0].enabled && length(aws_cognito_user_pool.this[0].sms_configuration) == 0
    error_message = "an authenticator app, not SMS"
  }

  assert {
    condition     = aws_cognito_user_pool.this[0].admin_create_user_config[0].allow_admin_create_user_only
    error_message = "nobody signs themselves up: being on the list is the only way in"
  }

  assert {
    condition     = aws_cognito_user_pool.this[0].email_configuration[0].email_sending_account == "COGNITO_DEFAULT" && aws_cognito_user_pool.this[0].deletion_protection == "ACTIVE"
    error_message = "Cognito's own email sender, and the pool cannot be deleted by accident"
  }

  assert {
    condition     = aws_cognito_user_pool_domain.this[0].domain == "acme-development-team-123456789012" && aws_cognito_user_pool_domain.this[0].managed_login_version == 2
    error_message = "a sign-in domain unique to the account, on managed login"
  }
}

run "production_has_no_front_door" {
  command = plan

  variables {
    environment = "production"
    front_door  = false
    read_only   = true
    people = {
      tunde = { email = "tunde@example.org", access = "read" }
    }
  }

  assert {
    condition     = length(aws_cognito_user_pool.this) == 0 && length(aws_cognito_user.person) == 0 && output.front_door == null
    error_message = "without a front door there is no user pool and no sign-in"
  }

  assert {
    condition     = output.usernames == { tunde = "platform.tunde" } && aws_secretsmanager_secret.this.name == "acme-database-people-production-secret-vault"
    error_message = "people still get a database login and a password"
  }
}

run "write_is_refused_where_everyone_is_read_only" {
  command = plan

  variables {
    read_only = true
  }

  expect_failures = [terraform_data.people_invariants]
}

run "nobody_listed_keeps_an_empty_secret" {
  command = plan

  variables {
    people = {}
  }

  assert {
    condition     = aws_secretsmanager_secret_version.this.secret_string == "{}" && length(aws_cognito_user.person) == 0
    error_message = "with nobody listed the secret is empty, which tells provisioning to remove every login, and there is no sign-in (the pool itself remains)"
  }
}

run "a_name_that_is_not_a_plain_identifier_is_refused" {
  command = plan

  variables {
    people = {
      "Ada-Lovelace" = { email = "ada@example.org", access = "read" }
    }
  }

  expect_failures = [var.people]
}

run "an_unknown_access_level_is_refused" {
  command = plan

  variables {
    people = {
      ada = { email = "ada@example.org", access = "admin" }
    }
  }

  expect_failures = [var.people]
}

run "a_shared_email_is_refused" {
  command = plan

  variables {
    people = {
      ada  = { email = "ada@example.org", access = "read" }
      ada2 = { email = "ADA@example.org", access = "read" }
    }
  }

  expect_failures = [var.people]
}

run "an_invalid_email_is_refused" {
  command = plan

  variables {
    people = {
      ada = { email = "ada-at-example", access = "read" }
    }
  }

  expect_failures = [var.people]
}

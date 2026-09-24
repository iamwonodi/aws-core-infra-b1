# Run with: terraform init -backend=false && terraform test   (no AWS access needed)
#
# Assertions use only values known at plan time: Terraform leaves computed
# attributes (IDs, ARNs) unknown in a planned test.

mock_provider "aws" {}
mock_provider "random" {}

variables {
  project_name = "acme"
  environment  = "development"

  people = {
    ada   = { email = "Ada@Example.org", access = "write" }
    tunde = { email = "tunde@example.org", access = "read" }
  }

}

run "each_person_gets_a_platform_login" {
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
    condition     = output.emails == tolist(["ada@example.org", "tunde@example.org"])
    error_message = "the list's emails, in lower case, for the front door's declaration"
  }
}

run "a_read_only_list_refuses_nothing_that_reads" {
  command = plan

  variables {
    environment = "production"
    read_only   = true
    people = {
      tunde = { email = "tunde@example.org", access = "read" }
    }
  }

  assert {
    condition     = output.usernames == { tunde = "platform.tunde" } && aws_secretsmanager_secret.this.name == "acme-database-people-production-secret-vault"
    error_message = "a login and a password, named for the environment"
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
    condition     = aws_secretsmanager_secret_version.this.secret_string == "{}" && length(output.emails) == 0
    error_message = "with nobody listed the secret is empty, which tells provisioning to remove every login, and nobody is declared to the front door"
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

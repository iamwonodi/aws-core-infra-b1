# Run with: terraform test   (from this module's directory; no AWS access needed)

variables {
  project_name   = "core"
  environment    = "development"
  aws_region     = "af-south-1"
  account_id     = "123456789012"
  subject_format = "immutable"

  deploy_bucket_name            = "core-development-deploy"
  isolated_security_group_id    = "sg-0iso111122223333a"
  database_update_document_name = "core-database-update"
  state_bucket_name             = "core-development-tfstate"
}

run "no_repository_grants_nothing" {
  command = plan

  assert {
    condition     = length(output.service_roles) == 0 && output.policy_size == null
    error_message = "without a repository there must be no role"
  }
}

run "a_repository_gets_a_scoped_role" {
  command = plan

  variables {
    repository = {
      name          = "acme/platform-databases"
      owner_id      = "10"
      repository_id = "20"
    }
  }

  assert {
    condition = output.service_roles["acme/platform-databases"].oidc_subjects == [
      "repo:acme@10/platform-databases@20:environment:development",
      "repo:acme@10/platform-databases@20:environment:development-plan",
    ]
    error_message = "the role must trust the <env> and <env>-plan environments"
  }

  assert {
    condition     = output.policy_size < 10240
    error_message = "the policy must fit IAM's 10,240 character limit"
  }

  assert {
    condition = alltrue([
      for needle in [
        "core-development-deploy/database/*",
        "document/core-database-update",
        "\"ssm:resourceTag/Service\":\"database-hub\"",
        "parameter/core/database/engines/*",
        "security-group/sg-0iso111122223333a",
        "core-development-tfstate/platform/database-engines/*",
        "repository/engines/*",
      ] : strcontains(output.service_roles["acme/platform-databases"].inline_policies["database-engines-access"], needle)
    ])
    error_message = "the policy must be scoped to the database engines' own resources"
  }

  assert {
    condition     = !strcontains(output.service_roles["acme/platform-databases"].inline_policies["database-engines-access"], "iam:") && !strcontains(output.service_roles["acme/platform-databases"].inline_policies["database-engines-access"], "\"Action\":\"*\"")
    error_message = "the policy must not grant IAM permissions or every action"
  }

  # The engines role must never be able to write the deploy bucket outside database/.
  assert {
    condition     = !strcontains(output.service_roles["acme/platform-databases"].inline_policies["database-engines-access"], "core-development-deploy/*") && !strcontains(output.service_roles["acme/platform-databases"].inline_policies["database-engines-access"], "core-development-deploy/private")
    error_message = "the engines role must not reach the fleet tiers' prefixes"
  }
}

run "a_repository_without_the_required_inputs_fails" {
  command = plan

  variables {
    database_update_document_name = null
    repository = {
      name          = "acme/platform-databases"
      owner_id      = "10"
      repository_id = "20"
    }
  }

  expect_failures = [terraform_data.engines_role_invariants]
}

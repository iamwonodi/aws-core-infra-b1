# Run with: terraform test   (from this module's directory; no AWS access needed)

variables {
  github_repository = "iamwonodi/audit"
  environment       = "development"
}

run "immutable_subjects_embed_the_ids" {
  command = plan

  variables {
    github_owner_id      = "111"
    github_repository_id = "222"
  }

  assert {
    condition = output.oidc_subjects == [
      "repo:iamwonodi@111/audit@222:environment:development",
      "repo:iamwonodi@111/audit@222:environment:development-plan",
    ]
    error_message = "immutable subjects must embed the owner and repository IDs and cover <env> and <env>-plan"
  }
}

run "classic_subjects_use_names_only" {
  command = plan

  variables {
    subject_format = "classic"
    environment    = "staging"
  }

  assert {
    condition = output.oidc_subjects == [
      "repo:iamwonodi/audit:environment:staging",
      "repo:iamwonodi/audit:environment:staging-plan",
    ]
    error_message = "classic subjects must use the repository name only"
  }
}

run "immutable_without_ids_fails" {
  command         = plan
  expect_failures = [terraform_data.identity_invariants]
}

run "immutable_with_a_non_numeric_id_fails" {
  command = plan

  variables {
    github_owner_id      = "abc"
    github_repository_id = "222"
  }

  expect_failures = [terraform_data.identity_invariants]
}

run "environment_already_ending_in_plan_is_rejected" {
  command = plan

  variables {
    environment          = "production-plan"
    github_owner_id      = "1"
    github_repository_id = "2"
  }

  expect_failures = [var.environment]
}

run "malformed_repository_is_rejected" {
  command = plan

  variables {
    github_repository    = "not-a-repository"
    github_owner_id      = "1"
    github_repository_id = "2"
  }

  expect_failures = [var.github_repository]
}

run "unknown_subject_format_is_rejected" {
  command = plan

  variables {
    subject_format = "weird"
  }

  expect_failures = [var.subject_format]
}

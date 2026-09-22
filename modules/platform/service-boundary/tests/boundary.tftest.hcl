# Run with: terraform test   (from this module's directory; no AWS access needed)

variables {
  project_name = "core"
  environment  = "production"
  aws_region   = "af-south-1"
  account_id   = "123456789012"

  deploy_bucket_name = "core-production-deploy"
}

run "the_boundary_is_named_and_placed_outside_the_services_namespace" {
  command = plan

  assert {
    condition     = output.policy_arn == "arn:aws:iam::123456789012:policy/platform/core-service-boundary"
    error_message = "the boundary lives at /platform/, never under /services/ where a service may create policies"
  }
}

run "it_confines_a_role_to_its_own_resources_through_the_service_tag" {
  command = plan

  assert {
    condition = alltrue([
      for needle in [
        "repository/${"$"}{aws:PrincipalTag/Service}/*",
        "core-${"$"}{aws:PrincipalTag/Service}-production-secret-vault-*",
        "core-production-${"$"}{aws:PrincipalTag/Service}-config/*",
        "parameter/core/services/${"$"}{aws:PrincipalTag/Service}/*",
      ] : strcontains(output.policy_json, needle)
    ])
    error_message = "every service-owned resource must be addressed through the Service principal tag"
  }
}

run "a_host_may_read_the_platform_scripts_and_nothing_else_in_that_bucket" {
  command = plan

  assert {
    condition     = strcontains(output.policy_json, "core-production-deploy/_platform/*")
    error_message = "core owns the deploy scripts, so a host must be able to read them"
  }

  # Another service's directory in the same bucket must stay out of reach.
  assert {
    condition     = !strcontains(output.policy_json, "core-production-deploy/*\"")
    error_message = "the boundary must not open the whole deploy bucket"
  }

  assert {
    condition     = strcontains(output.policy_json, "parameter/core/platform/scripts-manifest")
    error_message = "a host verifies what it downloads against the manifest, so it must be able to read it"
  }
}

run "it_denies_iam_and_role_assumption" {
  command = plan

  assert {
    condition     = strcontains(output.policy_json, "\"Effect\":\"Deny\"") && strcontains(output.policy_json, "iam:*") && strcontains(output.policy_json, "sts:AssumeRole")
    error_message = "an instance role must not be able to change IAM or assume another role"
  }
}

run "it_grants_nothing_broad" {
  command = plan

  assert {
    condition     = !strcontains(output.policy_json, "\"Action\":\"*\"") && !strcontains(output.policy_json, "s3:*") && !strcontains(output.policy_json, "secretsmanager:*")
    error_message = "the boundary is an allow-list of specific actions"
  }

  # Secrets are readable only under the project's own naming scheme.
  assert {
    condition     = !strcontains(output.policy_json, "secret:*")
    error_message = "secret access must be scoped to the service's own secret"
  }
}

run "it_fits_iams_managed_policy_limit" {
  command = plan

  assert {
    condition     = length(output.policy_json) < 6144
    error_message = "a managed policy may be at most 6,144 characters"
  }
}

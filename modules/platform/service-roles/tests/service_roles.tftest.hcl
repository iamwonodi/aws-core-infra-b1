# Run with: terraform init -backend=false && terraform test   (no AWS access needed)

# The roles' permissions are managed policies; the mock stands in for IAM.
mock_provider "aws" {}

variables {
  project_name   = "core"
  environment    = "development"
  aws_region     = "af-south-1"
  account_id     = "123456789012"
  subject_format = "immutable"

  tiers = {
    private = {
      listener_arn      = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/core-private-alb-development/50dc6c495c0c9188/f2f7dc8efc522ab2"
      asg_arn           = "arn:aws:autoscaling:af-south-1:123456789012:autoScalingGroup:11111111-2222-3333-4444-555555555555:autoScalingGroupName/core-development-private-asg"
      security_group_id = "sg-0aaa111122223333a"
    }
    internal = {
      listener_arn      = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/core-internal-alb-development/60dc6c495c0c9188/a2f7dc8efc522ab2"
      asg_arn           = "arn:aws:autoscaling:af-south-1:123456789012:autoScalingGroup:99999999-2222-3333-4444-555555555555:autoScalingGroupName/core-development-internal-asg"
      security_group_id = "sg-0bbb111122223333b"
    }
  }

  deploy_bucket_name               = "core-development-deploy"
  database_provision_document_name = "core-database-provision"
  assets_bucket_name               = "core-development-assets"
  state_bucket_name                = "core-development-tfstate"
  fleet_update_document_name       = "core-fleet-update"
}

# ------------------------------------------------------------------------------
# Shared fleet (development)
# ------------------------------------------------------------------------------

run "no_entries_produces_no_roles" {
  command = plan

  assert {
    condition     = length(output.service_roles) == 0
    error_message = "an empty service-roles.json must grant nothing"
  }
}

run "a_service_gets_two_roles_with_different_jobs" {
  command = plan

  variables {
    entries = {
      "acme/auth-infra" = { service_name = "auth", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
      "acme/auth-app"   = { service_name = "auth", kind = "app", tier = "private", owner_id = "1", repository_id = "3" }
    }
  }

  assert {
    condition     = length(output.service_roles) == 2
    error_message = "each repository must get its own role"
  }

  assert {
    condition = output.service_roles["acme/auth-app"].oidc_subjects == [
      "repo:acme@1/auth-app@3:environment:development",
      "repo:acme@1/auth-app@3:environment:development-plan",
    ]
    error_message = "the app role must trust the app repository's environments, with its own repository ID"
  }

  assert {
    condition     = max(concat(output.policy_sizes["acme/auth-app"], output.policy_sizes["acme/auth-infra"])...) <= 6144
    error_message = "every managed policy of both roles must fit IAM's 6,144 characters"
  }
}

run "the_app_role_can_only_deploy" {
  command = plan

  variables {
    entries = {
      "acme/auth-app" = { service_name = "auth", kind = "app", tier = "private", owner_id = "1", repository_id = "3" }
    }
  }

  assert {
    condition = alltrue([
      for needle in [
        "repository/auth/*",
        "core-development-deploy/private/auth/*",
        "core-development-assets/static/auth/*",
        "document/core-fleet-update",
        "\"ssm:resourceTag/Service\":\"private\"",
        "parameter/core/services/auth/*",
        "ecr:PutImage",
      ] : strcontains(output.policies["acme/auth-app"], needle)
    ])
    error_message = "the app role must be able to push, publish and redeploy, each scoped to its own service"
  }

  # It must not be able to create or change anything.
  assert {
    condition = alltrue([
      for forbidden in [
        "iam:", "ecr:CreateRepository", "ecr:DeleteRepository", "secretsmanager:", "elasticloadbalancing:CreateRule",
        "elasticloadbalancing:CreateTargetGroup", "ec2:Authorize", "autoscaling:Attach", "autoscaling:Create",
        "ssm:PutParameter", "tfstate",
      ] : !strcontains(output.policies["acme/auth-app"], forbidden)
    ])
    error_message = "the app role must not hold any Terraform-scale or IAM permission, nor touch state or secrets"
  }
}

run "the_infra_role_manages_only_the_services_own_resources" {
  command = plan

  variables {
    entries = {
      "acme/auth-infra" = { service_name = "auth", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  assert {
    condition = alltrue([
      for needle in [
        "repository/auth/*",
        "secret:core-auth-development-secret-vault-*",
        "targetgroup/core-auth-development-tg/*",
        "core-development-tfstate/services/auth/*",
        "parameter/core/services/auth/*",
        "parameter/core/platform/*",
        "ecr:PutImageScanningConfiguration",
        "\"aws:RequestTag/Service\":\"auth\"",
        "\"aws:ResourceTag/Service\":\"auth\"",
        "security-group/sg-0aaa111122223333a",
      ] : strcontains(output.policies["acme/auth-infra"], needle)
    ])
    error_message = "the infra role must be scoped to the service's own resources"
  }

  # Provisioning its own database: the request, the one document, the one host.
  assert {
    condition = alltrue([
      for needle in [
        "core-development-deploy/provisioning/auth/*",
        "document/core-database-provision",
        "\"ssm:resourceTag/Service\":\"database-hub\"",
      ] : strcontains(output.policies["acme/auth-infra"], needle)
    ])
    error_message = "the infra role must be able to provision its own database, through that one document, on the database host only"
  }

  # In the shared fleet nothing needs IAM, and the infra role publishes no files.
  assert {
    condition = alltrue([
      for forbidden in ["iam:", "ec2:RunInstances", "autoscaling:*", "ecr:PutImage\"", "static/auth", "fleet-update"] :
      !strcontains(output.policies["acme/auth-infra"], forbidden)
    ])
    error_message = "the shared-hosting infra role must hold no IAM, no host-creation and no application-deploy permission"
  }
}

run "without_a_database_host_no_provisioning_is_granted" {
  command = plan

  variables {
    database_provision_document_name = null
    entries = {
      "acme/auth-infra" = { service_name = "auth", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  assert {
    condition     = !strcontains(output.policies["acme/auth-infra"], "provisioning/auth")
    error_message = "where there is no database host to provision on, nothing is granted for it"
  }
}

run "an_internal_service_is_bound_to_its_own_tier" {
  command = plan

  variables {
    entries = {
      "a/one-app" = { service_name = "billing", kind = "app", tier = "internal", owner_id = "1", repository_id = "2" }
    }
  }

  assert {
    condition     = strcontains(output.policies["a/one-app"], "core-development-deploy/internal/billing/*")
    error_message = "an internal-tier service must publish under internal/<service>/"
  }
}

run "classic_format_needs_no_ids" {
  command = plan

  variables {
    subject_format = "classic"
    entries = {
      "a/one-app" = { service_name = "billing", kind = "app", tier = "internal" }
    }
  }

  assert {
    condition     = output.service_roles["a/one-app"].oidc_subjects[0] == "repo:a/one-app:environment:development"
    error_message = "classic subjects use names only"
  }
}

# ------------------------------------------------------------------------------
# Invariants
# ------------------------------------------------------------------------------

run "an_unknown_tier_fails" {
  command = plan

  variables {
    entries = {
      "a/one" = { service_name = "billing", kind = "app", tier = "edge", owner_id = "1", repository_id = "2" }
    }
  }

  expect_failures = [terraform_data.service_roles_invariants]
}

run "an_unknown_kind_fails" {
  command = plan

  variables {
    entries = {
      "a/one" = { service_name = "billing", kind = "both", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  expect_failures = [terraform_data.service_roles_invariants]
}

run "two_entries_of_the_same_kind_for_one_service_fail" {
  command = plan

  variables {
    entries = {
      "a/one" = { service_name = "billing", kind = "app", tier = "private", owner_id = "1", repository_id = "2" }
      "a/two" = { service_name = "billing", kind = "app", tier = "private", owner_id = "3", repository_id = "4" }
    }
  }

  expect_failures = [terraform_data.service_roles_invariants]
}

run "the_two_repositories_of_a_service_must_share_a_tier" {
  command = plan

  variables {
    entries = {
      "a/one" = { service_name = "billing", kind = "app", tier = "private", owner_id = "1", repository_id = "2" }
      "a/two" = { service_name = "billing", kind = "infra", tier = "internal", owner_id = "3", repository_id = "4" }
    }
  }

  expect_failures = [terraform_data.service_roles_invariants]
}

run "a_name_the_platform_uses_is_rejected" {
  command = plan

  variables {
    entries = {
      "a/one" = { service_name = "database-hub", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  expect_failures = [terraform_data.service_roles_invariants]
}

run "a_name_too_long_for_a_target_group_fails" {
  command = plan

  variables {
    entries = {
      "a/one" = { service_name = "averyveryverylongservice", kind = "app", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  expect_failures = [terraform_data.service_roles_invariants]
}

run "entries_without_the_required_buckets_fail" {
  command = plan

  variables {
    deploy_bucket_name = null
    entries = {
      "a/one" = { service_name = "billing", kind = "app", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  expect_failures = [terraform_data.service_roles_invariants]
}

run "a_shared_fleet_infra_entry_needs_the_fleet_resources" {
  command = plan

  variables {
    tiers = {
      private = { listener_arn = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/x/1/2" }
    }
    entries = {
      "a/one" = { service_name = "billing", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  expect_failures = [terraform_data.service_roles_invariants]
}

# ------------------------------------------------------------------------------
# Dedicated hosting (staging and production)
# ------------------------------------------------------------------------------

run "dedicated_infra_creates_its_own_hosts_but_only_under_the_boundary" {
  command = plan

  variables {
    hosting_model                    = "dedicated"
    environment                      = "production"
    permissions_boundary_arn         = "arn:aws:iam::123456789012:policy/platform/core-service-boundary"
    database_provision_document_name = null
    tiers = {
      private = { listener_arn = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/core-private-alb-production/50dc6c495c0c9188/f2f7dc8efc522ab2" }
    }
    entries = {
      "acme/auth-infra" = { service_name = "auth", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  assert {
    condition     = max(output.policy_sizes["acme/auth-infra"]...) <= 6144
    error_message = "every managed policy of the dedicated infra role must fit IAM's 6,144 characters"
  }

  # It can create roles only when they carry the boundary and the Service tag,
  # confined to the service's own IAM path.
  assert {
    condition = alltrue([
      for needle in [
        "\"iam:PermissionsBoundary\":\"arn:aws:iam::123456789012:policy/platform/core-service-boundary\"",
        "role/services/auth/*",
        "instance-profile/services/auth/*",
        "\"iam:PassedToService\":\"ec2.amazonaws.com\"",
        "autoScalingGroupName/core-production-auth-asg",
        "core-production-auth-config",
        "document/core-auth-*",
        "parameter/core/platform/*",
      ] : strcontains(output.policies["acme/auth-infra"], needle)
    ])
    error_message = "the dedicated infra role must create only its own, boundary-capped resources"
  }

  # The guard rails: removing the boundary or the tag, or editing the boundary policy, is denied outright.
  assert {
    condition = alltrue([
      for needle in [
        "\"Sid\":\"NeverRemoveTheBoundaryFromARole\"",
        "\"Sid\":\"NeverRemoveTheServiceTag\"",
        "\"Sid\":\"NeverChangeTheBoundaryPolicy\"",
        "iam:DeleteRolePermissionsBoundary",
      ] : strcontains(output.policies["acme/auth-infra"], needle)
    ])
    error_message = "the deny statements that protect the boundary must be present"
  }

  # No IAM statement may name a resource outside the service's own path.
  assert {
    condition     = !strcontains(output.policies["acme/auth-infra"], "role/*") && !strcontains(output.policies["acme/auth-infra"], "\"iam:*\"")
    error_message = "IAM permissions must never be broader than the service's own path"
  }
}

run "dedicated_app_publishes_to_its_own_bucket_and_redeploys_only_its_own_hosts" {
  command = plan

  variables {
    hosting_model                    = "dedicated"
    environment                      = "production"
    database_provision_document_name = null

    # Named here so the negative assertion below tests against this very bucket.
    deploy_bucket_name = "core-production-deploy"
    tiers = {
      private = { listener_arn = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/core-private-alb-production/50dc6c495c0c9188/f2f7dc8efc522ab2" }
    }
    entries = {
      "acme/auth-app" = { service_name = "auth", kind = "app", tier = "private", owner_id = "1", repository_id = "3" }
    }
  }

  assert {
    condition = alltrue([
      for needle in [
        "arn:aws:s3:::core-production-auth-config/*",
        "document/core-auth-update",
        "\"ssm:resourceTag/Service\":\"auth\"",
      ] : strcontains(output.policies["acme/auth-app"], needle)
    ])
    error_message = "the dedicated app role must use the service's own bucket, document and hosts"
  }

  assert {
    condition     = !strcontains(output.policies["acme/auth-app"], "iam:") && !strcontains(output.policies["acme/auth-app"], "core-production-deploy")
    error_message = "the app role never holds IAM, and never touches the shared deploy bucket in a dedicated environment"
  }
}

run "the_largest_role_fits_its_managed_policies" {
  command = plan

  # The largest policy there is: a dedicated infra role for the longest service
  # name production allows (13 characters), in a long Region name, with all three
  # engines and the front door. As one inline policy it was about 10,700
  # characters, over IAM's 10,240.
  variables {
    hosting_model            = "dedicated"
    environment              = "production"
    aws_region               = "ap-southeast-1"
    permissions_boundary_arn = "arn:aws:iam::123456789012:policy/platform/core-service-boundary"
    front_door_enabled       = true
    database_provision_function_arns = [
      "arn:aws:lambda:ap-southeast-1:123456789012:function:core-production-mysql-provision",
      "arn:aws:lambda:ap-southeast-1:123456789012:function:core-production-postgres-provision",
      "arn:aws:lambda:ap-southeast-1:123456789012:function:core-production-mongodb-provision",
    ]
    deploy_bucket_name = "core-production-deploy"
    tiers = {
      private = { listener_arn = "arn:aws:elasticloadbalancing:ap-southeast-1:123456789012:listener/app/core-private-alb-production/50dc6c495c0c9188/f2f7dc8efc522ab2" }
    }
    entries = {
      "a-long-github-organisation/a-long-service-name-infra" = { service_name = "abcdefghijklm", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  assert {
    condition     = length(output.policies["a-long-github-organisation/a-long-service-name-infra"]) > 10240
    error_message = "this case is meant to be larger than one inline policy could hold"
  }

  assert {
    condition     = max(output.policy_sizes["a-long-github-organisation/a-long-service-name-infra"]...) <= 6144
    error_message = "every managed policy must fit IAM's 6,144 characters"
  }

  assert {
    condition     = length(output.policy_sizes["a-long-github-organisation/a-long-service-name-infra"]) <= 10
    error_message = "a role may have at most 10 managed policies"
  }

  # Every statement is in exactly one managed policy, in order: nothing lost,
  # nothing doubled.
  assert {
    condition = jsondecode(output.policies["a-long-github-organisation/a-long-service-name-infra"]).Statement == flatten([
      for n in range(length(output.policy_sizes["a-long-github-organisation/a-long-service-name-infra"])) :
      jsondecode(aws_iam_policy.service["a-long-github-organisation/a-long-service-name-infra#${n + 1}"].policy).Statement
    ])
    error_message = "the managed policies together must hold exactly the role's statements"
  }
}

run "the_policies_are_where_the_role_cannot_change_them" {
  command = plan

  variables {
    hosting_model            = "dedicated"
    environment              = "production"
    permissions_boundary_arn = "arn:aws:iam::123456789012:policy/platform/core-service-boundary"
    tiers = {
      private = { listener_arn = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/x/1/2" }
    }
    entries = {
      "acme/auth-infra" = { service_name = "auth", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
      "acme/auth-app"   = { service_name = "auth", kind = "app", tier = "private", owner_id = "1", repository_id = "3" }
    }
  }

  # A dedicated infra role may create and change policies under
  # /services/<service>/; its own permissions must not be there.
  assert {
    condition     = alltrue([for policy in aws_iam_policy.service : policy.path == "/platform/service-roles/"])
    error_message = "the managed policies must live under /platform/service-roles/"
  }

  assert {
    condition = alltrue([
      for repository in ["acme/auth-infra", "acme/auth-app"] : alltrue([
        for arn in output.service_roles[repository].policy_arns :
        startswith(arn, "arn:aws:iam::123456789012:policy/platform/service-roles/core-production-auth-")
      ])
    ])
    error_message = "each role is given its own policies, by the ARN IAM will give them"
  }

  assert {
    condition     = length(output.service_roles["acme/auth-infra"].policy_arns) == length(output.policy_sizes["acme/auth-infra"]) && length(output.service_roles["acme/auth-app"].policy_arns) == length(output.policy_sizes["acme/auth-app"])
    error_message = "each role gets every one of its policies, and no other role's"
  }

  assert {
    condition     = output.service_roles["acme/auth-infra"].inline_policies == {} && output.service_roles["acme/auth-app"].inline_policies == {}
    error_message = "no permissions remain inline"
  }

  # Known at plan: the OIDC module keys its attachments by these ARNs.
  assert {
    condition     = output.service_roles["acme/auth-infra"].policy_arns[0] == "arn:aws:iam::123456789012:policy/platform/service-roles/core-production-auth-infra-1"
    error_message = "the ARNs must be known at plan"
  }
}

run "a_dedicated_infra_role_may_invoke_the_provisioning_function_and_nothing_else" {
  command = plan

  variables {
    hosting_model                    = "dedicated"
    environment                      = "production"
    permissions_boundary_arn         = "arn:aws:iam::123456789012:policy/platform/core-service-boundary"
    database_provision_function_arns = ["arn:aws:lambda:af-south-1:123456789012:function:core-production-postgres-provision"]

    tiers = {
      private = { listener_arn = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/x/1/2" }
    }
    entries = {
      "acme/auth-infra" = { service_name = "auth", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
      "acme/auth-app"   = { service_name = "auth", kind = "app", tier = "private", owner_id = "1", repository_id = "3" }
    }
  }

  assert {
    condition     = strcontains(output.policies["acme/auth-infra"], "function:core-production-postgres-provision")
    error_message = "the infra role must be able to invoke core's provisioning function"
  }

  assert {
    condition     = !strcontains(output.policies["acme/auth-app"], "lambda:")
    error_message = "the app role never provisions anything"
  }

  # Invoking one named function is all it gets: no lambda:* and no other function.
  assert {
    condition     = !strcontains(output.policies["acme/auth-infra"], "lambda:*") && !strcontains(output.policies["acme/auth-infra"], "function:*")
    error_message = "Lambda permissions must name the one function"
  }

  assert {
    condition     = max(output.policy_sizes["acme/auth-infra"]...) <= 6144
    error_message = "the policy must still fit IAM's limit"
  }
}

run "a_dedicated_infra_entry_needs_the_boundary" {
  command = plan

  variables {
    hosting_model = "dedicated"
    tiers = {
      private = { listener_arn = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/x/1/2" }
    }
    entries = {
      "a/one" = { service_name = "billing", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  expect_failures = [terraform_data.service_roles_invariants]
}

run "a_dedicated_infra_role_may_invoke_every_engines_provisioning_function" {
  command = plan

  variables {
    hosting_model            = "dedicated"
    environment              = "production"
    permissions_boundary_arn = "arn:aws:iam::123456789012:policy/platform/core-service-boundary"
    database_provision_function_arns = [
      "arn:aws:lambda:af-south-1:123456789012:function:core-production-mysql-provision",
      "arn:aws:lambda:af-south-1:123456789012:function:core-production-postgres-provision",
    ]

    tiers = {
      private = { listener_arn = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/x/1/2" }
    }
    entries = {
      "acme/auth-infra" = { service_name = "auth", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  assert {
    condition = alltrue([
      for fn in ["function:core-production-postgres-provision", "function:core-production-mysql-provision"] :
      strcontains(output.policies["acme/auth-infra"], fn)
    ])
    error_message = "the infra role must be able to invoke each engine's provisioning function"
  }

  assert {
    condition     = max(output.policy_sizes["acme/auth-infra"]...) <= 6144
    error_message = "each of the infra role's managed policies must stay within IAM's 6,144 characters with two engines"
  }
}

run "no_managed_database_grants_no_invoke" {
  command = plan

  variables {
    hosting_model            = "dedicated"
    environment              = "production"
    permissions_boundary_arn = "arn:aws:iam::123456789012:policy/platform/core-service-boundary"

    tiers = {
      private = { listener_arn = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/x/1/2" }
    }
    entries = {
      "acme/auth-infra" = { service_name = "auth", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  assert {
    condition     = !strcontains(output.policies["acme/auth-infra"], "lambda:InvokeFunction")
    error_message = "with no managed database, the infra role may invoke nothing"
  }
}

run "a_reserved_service_name_fails" {
  command = plan

  variables {
    entries = {
      "a/one" = { service_name = "database-hub", kind = "app", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  expect_failures = [terraform_data.service_roles_invariants]
}

run "a_name_in_the_platforms_database_family_fails" {
  command = plan

  # Would be <project>-database-admin-mysql-<env>-secret-vault: the MySQL
  # administrator's secret in staging and production.
  variables {
    entries = {
      "a/one" = { service_name = "database-admin-mysql", kind = "app", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  expect_failures = [terraform_data.service_roles_invariants]
}

run "a_name_merely_containing_a_reserved_word_is_allowed" {
  command = plan

  variables {
    entries = {
      "a/one" = { service_name = "mydatabase", kind = "app", tier = "private", owner_id = "1", repository_id = "2" }
      "a/two" = { service_name = "platform-api", kind = "app", tier = "private", owner_id = "3", repository_id = "4" }
    }
  }

  assert {
    condition     = length(output.service_roles) == 2
    error_message = "only names BEGINNING with a reserved prefix are refused, and people's logins reserve none"
  }
}

run "a_service_declares_its_own_agents_to_the_front_door_and_nothing_else" {
  command = plan

  variables {
    front_door_enabled = true
    entries = {
      "acme/auth-infra" = { service_name = "auth", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
      "acme/auth-app"   = { service_name = "auth", kind = "app", tier = "private", owner_id = "1", repository_id = "3" }
    }
  }

  assert {
    condition = anytrue([
      for statement in jsondecode(output.policies["acme/auth-infra"]).Statement :
      statement.Sid == "DeclareOwnAgentsToTheFrontDoor" && statement.Resource == "arn:aws:s3:::core-development-deploy/front-door/auth.json"
    ])
    error_message = "the infrastructure role may write its own declaration, one object named after the service"
  }

  assert {
    condition = alltrue([
      for statement in jsondecode(output.policies["acme/auth-infra"]).Statement :
      !can(regex("front-door/(\\*|[^a]|a[^u])", jsonencode(statement.Resource)))
    ])
    error_message = "and no other object in front-door/: not another service's, not a wildcard"
  }

  assert {
    condition     = !strcontains(output.policies["acme/auth-app"], "front-door/")
    error_message = "the app role declares nothing"
  }

  assert {
    condition     = !strcontains(output.policies["acme/auth-infra"], "cognito")
    error_message = "no service role touches Cognito"
  }
}

run "without_a_front_door_nothing_is_declared" {
  command = plan

  variables {
    entries = {
      "acme/auth-infra" = { service_name = "auth", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  assert {
    condition     = !strcontains(output.policies["acme/auth-infra"], "front-door/")
    error_message = "production has no front door, so no declaration"
  }
}

run "the_team_tools_tag_is_reserved" {
  command = plan

  variables {
    entries = {
      "a/one" = { service_name = "team-tools", kind = "infra", tier = "private", owner_id = "1", repository_id = "2" }
    }
  }

  expect_failures = [terraform_data.service_roles_invariants]
}

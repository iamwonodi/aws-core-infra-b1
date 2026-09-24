# Run with: terraform test   (from this module's directory; no AWS access needed)

variables {
  project_name   = "core"
  environment    = "development"
  aws_region     = "af-south-1"
  account_id     = "123456789012"
  subject_format = "immutable"

  state_bucket_name        = "core-development-tfstate"
  permissions_boundary_arn = "arn:aws:iam::123456789012:policy/platform/core-service-boundary"
  ami_parameter_name       = "/core/platform/ami/golden"
  listener_arn             = "arn:aws:elasticloadbalancing:af-south-1:123456789012:listener/app/core-private/abc/def"
  user_pool_arn            = "arn:aws:cognito-idp:af-south-1:123456789012:userpool/af-south-1_Abc"
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
    repository = { name = "acme/team-tools", owner_id = "111", repository_id = "222" }
  }

  assert {
    condition     = keys(output.service_roles) == tolist(["acme/team-tools"])
    error_message = "one role, for the repository"
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.service_roles["acme/team-tools"].inline_policies["team-tools-access"]).Statement :
      s.Effect == "Deny" || s.Resource == "*" && startswith(s.Sid, "ReadOnly") || !strcontains(jsonencode(s.Resource), "\"*\"")
    ])
    error_message = "only read-only lookups and the guard rails name every resource"
  }

  assert {
    condition = length(distinct([
      for s in jsondecode(output.service_roles["acme/team-tools"].inline_policies["team-tools-access"]).Statement : s.Sid
    ])) == length(jsondecode(output.service_roles["acme/team-tools"].inline_policies["team-tools-access"]).Statement)
    error_message = "every statement's Sid is unique, which IAM requires"
  }

  assert {
    condition     = output.policy_size <= 10240
    error_message = "the policy fits IAM's inline limit"
  }
}

run "everything_it_creates_is_tagged_team_tools_or_named_so" {
  command = plan

  variables {
    repository = { name = "acme/team-tools", owner_id = "111", repository_id = "222" }
  }

  assert {
    condition = alltrue([
      for s in jsondecode(output.service_roles["acme/team-tools"].inline_policies["team-tools-access"]).Statement :
      try(s.Condition.StringEquals["aws:RequestTag/Service"], "team-tools") == "team-tools"
      && try(s.Condition.StringEquals["ec2:ResourceTag/Service"], "team-tools") == "team-tools"
      && try(s.Condition.StringEquals["aws:ResourceTag/Service"], "team-tools") == "team-tools"
    ])
    error_message = "every tag condition names team-tools"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.service_roles["acme/team-tools"].inline_policies["team-tools-access"]).Statement :
      s.Sid == "CreateRolesOnlyWithTheBoundary" && s.Condition.StringEquals["iam:PermissionsBoundary"] == "arn:aws:iam::123456789012:policy/platform/core-service-boundary" && s.Resource == "arn:aws:iam::123456789012:role/services/team-tools/*"
    ])
    error_message = "its instance role is created only with core's boundary, under /services/team-tools/"
  }

  assert {
    condition = anytrue([
      for s in jsondecode(output.service_roles["acme/team-tools"].inline_policies["team-tools-access"]).Statement :
      s.Sid == "OwnAutoScalingGroup" && contains(s.Resource, "arn:aws:autoscaling:af-south-1:123456789012:scheduledUpdateGroupAction:*:autoScalingGroupName/core-development-team-tools-asg:scheduledActionName/*")
    ])
    error_message = "its own group's scheduled actions: the schedules, Start and auto-off"
  }

  assert {
    condition     = !strcontains(output.service_roles["acme/team-tools"].inline_policies["team-tools-access"], "cognito-idp:Admin") && !strcontains(output.service_roles["acme/team-tools"].inline_policies["team-tools-access"], "secretsmanager")
    error_message = "it manages no Cognito user and reads no secret"
  }
}

run "the_front_door_statements_only_where_there_is_one" {
  command = plan

  variables {
    environment   = "production"
    listener_arn  = null
    user_pool_arn = null
    repository    = { name = "acme/team-tools", owner_id = "111", repository_id = "222" }
  }

  assert {
    condition     = !strcontains(output.service_roles["acme/team-tools"].inline_policies["team-tools-access"], "elasticloadbalancing:CreateRule") && !strcontains(output.service_roles["acme/team-tools"].inline_policies["team-tools-access"], "cognito-idp")
    error_message = "production's tools have no web address: no listener rules, no app client"
  }
}

run "a_repository_without_its_inputs_is_refused" {
  command = plan

  variables {
    repository               = { name = "acme/team-tools", owner_id = "111", repository_id = "222" }
    permissions_boundary_arn = null
  }

  expect_failures = [terraform_data.tools_role_invariants]
}

run "report_the_policy_size" {
  command = plan

  variables {
    repository = { name = "acme/team-tools", owner_id = "111", repository_id = "222" }
  }

  assert {
    condition     = output.policy_size > 0
    error_message = "size: ${output.policy_size}"
  }
}

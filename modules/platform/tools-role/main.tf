# ------------------------------------------------------------------------------
# TEAM TOOLS ROLE
#
# The team's own tools (the database GUIs, later others) are run by their own
# repository. Core makes room for them (the team-tools security group, the front
# door, database access); that repository runs them: their hosts, schedules and
# web addresses. This module generates the role its pipeline assumes, scoped to
# exactly that, the way engines-role does for the platforms team.
#
# Everything the repository creates is tagged Service=team-tools, and its IAM
# lives under /services/team-tools/ with core's permissions boundary, whose
# ${aws:PrincipalTag/Service} confines the tools' instance role to the SSM agent
# and team-tools' own names. "team-tools" is a reserved service name, so no
# service can ever share the tag.
#
# It grants nothing until a repository is set.
#
# WHAT AWS CANNOT SCOPE: creating an app client on the user pool cannot be
# limited to some clients. A client alone admits no one (sign-ins come only from
# the front door's declarations), but it is why this repository's changes need
# review.
# ------------------------------------------------------------------------------

locals {
  enabled = var.repository != null
  tag     = "team-tools"

  front_door = var.listener_arn != null && var.user_pool_arn != null

  missing_inputs = local.enabled ? [
    for name, value in {
      state_bucket_name        = var.state_bucket_name
      permissions_boundary_arn = var.permissions_boundary_arn
      ami_parameter_name       = var.ami_parameter_name
    } : name if value == null
  ] : []

  ra       = "${var.aws_region}:${var.account_id}"
  iam      = "arn:aws:iam::${var.account_id}"
  boundary = coalesce(var.permissions_boundary_arn, "${local.iam}:policy/platform/unset")
  asg_name = "${var.project_name}-${var.environment}-${local.tag}-asg"

  # ---- always ----------------------------------------------------------------

  # Each statement is encoded on its own, so that the optional group below can
  # be an empty list of the same type (strings) when it does not apply.
  st_always = [for statement in [
    {
      Sid    = "ReadPlatformContractAndGoldenAmi"
      Effect = "Allow"
      Action = ["ssm:GetParameter", "ssm:GetParameters"]
      Resource = [
        "arn:aws:ssm:${local.ra}:parameter/${var.project_name}/platform/config",
        "arn:aws:ssm:${local.ra}:parameter/${trimprefix(coalesce(var.ami_parameter_name, "unset"), "/")}",
      ]
    },
    {
      Sid    = "ReadOnlyLookups"
      Effect = "Allow"
      Action = [
        "autoscaling:Describe*", "ec2:Describe*", "elasticloadbalancing:Describe*", "ssm:DescribeParameters",
      ]
      Resource = "*"
    },

    # --- its own security group -----------------------------------------------
    {
      Sid      = "CreateSecurityGroupInAVpc"
      Effect   = "Allow"
      Action   = ["ec2:CreateSecurityGroup"]
      Resource = "arn:aws:ec2:${local.ra}:vpc/*"
    },
    {
      Sid       = "CreateSecurityGroupTaggedForTheTools"
      Effect    = "Allow"
      Action    = ["ec2:CreateSecurityGroup"]
      Resource  = "arn:aws:ec2:${local.ra}:security-group/*"
      Condition = { StringEquals = { "aws:RequestTag/Service" = local.tag } }
    },
    {
      Sid    = "ManageOwnSecurityGroups"
      Effect = "Allow"
      Action = [
        "ec2:AuthorizeSecurityGroupEgress", "ec2:AuthorizeSecurityGroupIngress", "ec2:DeleteSecurityGroup",
        "ec2:ModifySecurityGroupRules", "ec2:RevokeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress",
        "ec2:UpdateSecurityGroupRuleDescriptionsEgress", "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
      ]
      Resource  = "arn:aws:ec2:${local.ra}:security-group/*"
      Condition = { StringEquals = { "ec2:ResourceTag/Service" = local.tag } }
    },
    {
      Sid      = "SecurityGroupRules"
      Effect   = "Allow"
      Action   = ["ec2:ModifySecurityGroupRules", "ec2:CreateTags", "ec2:DeleteTags"]
      Resource = "arn:aws:ec2:${local.ra}:security-group-rule/*"
    },

    # --- launch template and the instances it starts ---------------------------
    {
      Sid       = "CreateLaunchTemplateTaggedForTheTools"
      Effect    = "Allow"
      Action    = ["ec2:CreateLaunchTemplate"]
      Resource  = "arn:aws:ec2:${local.ra}:launch-template/*"
      Condition = { StringEquals = { "aws:RequestTag/Service" = local.tag } }
    },
    {
      Sid    = "ManageOwnLaunchTemplates"
      Effect = "Allow"
      Action = [
        "ec2:CreateLaunchTemplateVersion", "ec2:DeleteLaunchTemplate", "ec2:DeleteLaunchTemplateVersions",
        "ec2:ModifyLaunchTemplate",
      ]
      Resource  = "arn:aws:ec2:${local.ra}:launch-template/*"
      Condition = { StringEquals = { "ec2:ResourceTag/Service" = local.tag } }
    },
    {
      Sid      = "TagOnCreate"
      Effect   = "Allow"
      Action   = ["ec2:CreateTags"]
      Resource = "arn:aws:ec2:${local.ra}:*/*"
      Condition = {
        StringEquals = {
          "ec2:CreateAction"       = ["CreateLaunchTemplate", "CreateSecurityGroup", "RunInstances"]
          "aws:RequestTag/Service" = local.tag
        }
      }
    },
    # An Auto Scaling group's launch template is checked against the caller's
    # permissions.
    {
      Sid       = "RunInstancesTaggedForTheTools"
      Effect    = "Allow"
      Action    = ["ec2:RunInstances"]
      Resource  = ["arn:aws:ec2:${local.ra}:instance/*", "arn:aws:ec2:${local.ra}:network-interface/*", "arn:aws:ec2:${local.ra}:volume/*"]
      Condition = { StringEquals = { "aws:RequestTag/Service" = local.tag } }
    },
    {
      Sid    = "RunInstancesSupportingResources"
      Effect = "Allow"
      Action = ["ec2:RunInstances"]
      Resource = [
        "arn:aws:ec2:${local.ra}:image/*", "arn:aws:ec2:${local.ra}:launch-template/*",
        "arn:aws:ec2:${local.ra}:security-group/*", "arn:aws:ec2:${local.ra}:spot-instances-request/*",
        "arn:aws:ec2:${local.ra}:subnet/*",
      ]
    },

    # --- its own Auto Scaling group: the schedules, the Start button and auto-off
    # are scheduled actions and desired-capacity changes on this group ----------
    {
      Sid    = "OwnAutoScalingGroup"
      Effect = "Allow"
      Action = ["autoscaling:*"]
      Resource = [
        "arn:aws:autoscaling:${local.ra}:autoScalingGroup:*:autoScalingGroupName/${local.asg_name}",
        "arn:aws:autoscaling:${local.ra}:scheduledUpdateGroupAction:*:autoScalingGroupName/${local.asg_name}:scheduledActionName/*",
      ]
    },

    # --- the instance role, capped by the permissions boundary ------------------
    {
      Sid       = "CreateRolesOnlyWithTheBoundary"
      Effect    = "Allow"
      Action    = ["iam:CreateRole"]
      Resource  = "${local.iam}:role/services/${local.tag}/*"
      Condition = { StringEquals = { "iam:PermissionsBoundary" = local.boundary, "aws:RequestTag/Service" = local.tag } }
    },
    {
      Sid       = "SetOnlyTheBoundary"
      Effect    = "Allow"
      Action    = ["iam:PutRolePermissionsBoundary"]
      Resource  = "${local.iam}:role/services/${local.tag}/*"
      Condition = { StringEquals = { "iam:PermissionsBoundary" = local.boundary } }
    },
    {
      Sid    = "ManageOwnRoles"
      Effect = "Allow"
      Action = [
        "iam:AttachRolePolicy", "iam:DeleteRole", "iam:DeleteRolePolicy", "iam:DetachRolePolicy",
        "iam:PutRolePolicy", "iam:UpdateAssumeRolePolicy", "iam:UpdateRole", "iam:UpdateRoleDescription",
      ]
      Resource = "${local.iam}:role/services/${local.tag}/*"
    },
    {
      Sid       = "TagOwnRolesWithTheirService"
      Effect    = "Allow"
      Action    = ["iam:TagRole"]
      Resource  = "${local.iam}:role/services/${local.tag}/*"
      Condition = { StringEquals = { "aws:RequestTag/Service" = local.tag } }
    },
    {
      Sid    = "OwnInstanceProfiles"
      Effect = "Allow"
      Action = [
        "iam:AddRoleToInstanceProfile", "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
      ]
      Resource = "${local.iam}:instance-profile/services/${local.tag}/*"
    },
    {
      Sid       = "PassOwnRolesToEc2Only"
      Effect    = "Allow"
      Action    = ["iam:PassRole"]
      Resource  = "${local.iam}:role/services/${local.tag}/*"
      Condition = { StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" } }
    },
    {
      Sid    = "ReadOwnIam"
      Effect = "Allow"
      Action = ["iam:Get*", "iam:List*"]
      Resource = [
        "${local.iam}:role/services/${local.tag}/*",
        "${local.iam}:instance-profile/services/${local.tag}/*",
      ]
    },
    {
      Sid      = "ServiceLinkedRolesForScalingAndSpot"
      Effect   = "Allow"
      Action   = ["iam:CreateServiceLinkedRole"]
      Resource = ["${local.iam}:role/aws-service-role/autoscaling.amazonaws.com/*", "${local.iam}:role/aws-service-role/spot.amazonaws.com/*"]
      Condition = {
        StringEquals = { "iam:AWSServiceName" = ["autoscaling.amazonaws.com", "spot.amazonaws.com"] }
      }
    },

    # --- its own Terraform state ---------------------------------------------
    {
      Sid      = "StateOwnPrefix"
      Effect   = "Allow"
      Action   = ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
      Resource = "arn:aws:s3:::${coalesce(var.state_bucket_name, "unset")}/${var.state_prefix}/*"
    },
    {
      Sid       = "StateList"
      Effect    = "Allow"
      Action    = ["s3:GetBucketLocation", "s3:ListBucket"]
      Resource  = "arn:aws:s3:::${coalesce(var.state_bucket_name, "unset")}"
      Condition = { StringLike = { "s3:prefix" = [var.state_prefix, "${var.state_prefix}/*"] } }
    },

    # --- the guard rails: these override every Allow above ----------------------
    {
      Sid      = "NeverRemoveTheBoundaryFromARole"
      Effect   = "Deny"
      Action   = ["iam:DeleteRolePermissionsBoundary"]
      Resource = "*"
    },
    {
      Sid       = "NeverRemoveTheServiceTag"
      Effect    = "Deny"
      Action    = ["iam:UntagRole"]
      Resource  = "*"
      Condition = { "ForAnyValue:StringEquals" = { "aws:TagKeys" = ["Service"] } }
    },
    {
      Sid      = "NeverChangeTheBoundaryPolicy"
      Effect   = "Deny"
      Action   = ["iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion"]
      Resource = local.boundary
    },
  ] : jsonencode(statement)]

  # ---- where the tools have web addresses (development, staging) ---------------

  rule_arns = "${replace(coalesce(var.listener_arn, "unset:listener/"), ":listener/", ":listener-rule/")}/*"

  st_front_door = local.front_door ? [for statement in [
    {
      Sid       = "TargetGroupCreateTaggedForTheTools"
      Effect    = "Allow"
      Action    = ["elasticloadbalancing:CreateTargetGroup"]
      Resource  = "arn:aws:elasticloadbalancing:${local.ra}:targetgroup/*/*"
      Condition = { StringEquals = { "aws:RequestTag/Service" = local.tag } }
    },
    {
      Sid      = "TagLoadBalancerResourcesOnCreate"
      Effect   = "Allow"
      Action   = ["elasticloadbalancing:AddTags"]
      Resource = ["arn:aws:elasticloadbalancing:${local.ra}:targetgroup/*/*", local.rule_arns]
      Condition = {
        StringEquals = {
          "elasticloadbalancing:CreateAction" = ["CreateTargetGroup", "CreateRule"]
          "aws:RequestTag/Service"            = local.tag
        }
      }
    },
    {
      Sid    = "ManageOwnTargetGroups"
      Effect = "Allow"
      Action = [
        "elasticloadbalancing:AddTags", "elasticloadbalancing:DeleteTargetGroup", "elasticloadbalancing:ModifyTargetGroup",
        "elasticloadbalancing:ModifyTargetGroupAttributes", "elasticloadbalancing:RemoveTags",
      ]
      Resource  = "arn:aws:elasticloadbalancing:${local.ra}:targetgroup/*/*"
      Condition = { StringEquals = { "aws:ResourceTag/Service" = local.tag } }
    },
    {
      Sid       = "ListenerRuleCreateTaggedForTheTools"
      Effect    = "Allow"
      Action    = ["elasticloadbalancing:CreateRule"]
      Resource  = var.listener_arn
      Condition = { StringEquals = { "aws:RequestTag/Service" = local.tag } }
    },
    {
      Sid    = "ListenerRuleManageOnlyTheToolsRules"
      Effect = "Allow"
      Action = [
        "elasticloadbalancing:AddTags", "elasticloadbalancing:DeleteRule", "elasticloadbalancing:ModifyRule",
        "elasticloadbalancing:RemoveTags", "elasticloadbalancing:SetRulePriorities",
      ]
      Resource  = local.rule_arns
      Condition = { StringEquals = { "aws:ResourceTag/Service" = local.tag } }
    },
    # Its app client and the client's managed login style. No user management:
    # who may sign in is the front door's declarations.
    {
      Sid    = "OwnAppClientAndLoginStyle"
      Effect = "Allow"
      Action = [
        "cognito-idp:CreateManagedLoginBranding", "cognito-idp:CreateUserPoolClient",
        "cognito-idp:DeleteManagedLoginBranding", "cognito-idp:DeleteUserPoolClient",
        "cognito-idp:DescribeManagedLoginBranding", "cognito-idp:DescribeManagedLoginBrandingByClient",
        "cognito-idp:DescribeUserPool", "cognito-idp:DescribeUserPoolClient", "cognito-idp:DescribeUserPoolDomain",
        "cognito-idp:ListUserPoolClients", "cognito-idp:UpdateManagedLoginBranding", "cognito-idp:UpdateUserPoolClient",
      ]
      Resource = var.user_pool_arn
    },
  ] : jsonencode(statement)] : []

  policy = local.enabled && length(local.missing_inputs) == 0 ? "{\"Version\":\"2012-10-17\",\"Statement\":[${join(",", concat(local.st_always, local.st_front_door))}]}" : null
}

module "identity" {
  source = "../identity"
  count  = local.enabled ? 1 : 0

  github_repository    = var.repository.name
  github_owner_id      = var.repository.owner_id
  github_repository_id = var.repository.repository_id
  subject_format       = var.subject_format
  environment          = var.environment
}

resource "terraform_data" "tools_role_invariants" {
  lifecycle {
    precondition {
      condition     = length(local.missing_inputs) == 0
      error_message = "A team-tools repository is set, so these inputs are required but not set: ${join(", ", local.missing_inputs)}."
    }

    # IAM allows 10,240 characters across a role's inline policies.
    precondition {
      condition     = local.policy == null ? true : length(local.policy) <= 10240
      error_message = "The team-tools policy is ${local.policy == null ? 0 : length(local.policy)} characters, over IAM's 10,240 for a role's inline policies."
    }
  }
}

# ------------------------------------------------------------------------------
# SERVICE ROLES
#
# Turns the entries of service-roles.json into the input of the OIDC module's
# service_roles: for each repository, the token subjects to trust and a scoped
# inline policy.
#
# TWO ROLES PER SERVICE. A service has two repositories with different jobs, so
# each gets a role that can do only its own job:
#
#   kind "infra"  the repository holding the service's Terraform. It creates and
#                 changes the service's cloud resources, so it holds the
#                 Terraform-scale permissions -- including, in a dedicated
#                 environment, IAM, limited by a permissions boundary.
#   kind "app"    the repository that builds and deploys the application. It
#                 pushes an image, publishes files and triggers a redeploy. It
#                 holds no permission to create or change any resource, and none
#                 over IAM.
#
# The two find each other through one SSM parameter per service,
# /<project>/services/<service>/config, which the infra role writes and the app
# role reads.
#
# THE POLICY IS GENERATED, NOT HAND-WRITTEN. It is built from the service's name
# and tier, so every resource it names carries that service's own name -- the ECR
# repository <service>/*, the secret <project>-<service>-<env>-secret-vault, the
# target group <project>-<service>-<env>-tg, the S3 prefixes, its own state key,
# and (dedicated) its own ASG, security group, bucket and IAM path /services/<service>/.
#
# HOSTING MODELS
#   shared        development: services run on the shared tier fleets.
#   dedicated     staging and production: each service's infra repository creates
#                 its own launch template, ASG, security group, configuration
#                 bucket and instance role. The role it creates must carry the
#                 permissions boundary, so it can never be more powerful than the
#                 boundary allows, whatever is attached to it.
#
# WHAT AWS CANNOT SCOPE. Some actions cannot be limited to one service:
#   - ecr:GetAuthorizationToken and the Describe* read calls need "*".
#   - shared: the shared tier security group can be changed by any service's
#     infra role and AWS cannot limit which port or source a rule opens; a target
#     group can be detached from the shared ASG by any service. Rely on review.
#   - dedicated: launch-template and security-group resources have no name in their
#     ARN, so they are scoped by the Service tag instead of by name.
# ALB rules ARE protected: a rule may only be created with, and later changed only
# while it carries, a Service tag equal to the service's name.
#
# Where an action list would run to a dozen names, a wildcard is used instead
# (secretsmanager:* on the service's own secret, autoscaling:* on its own group,
# iam:Get*/List* on its own IAM path): the RESOURCE is what confines it, and the
# policy must stay under IAM's size limit. When further statements are
# added the dedicated infra policy will outgrow one inline policy and must be split
# into managed policies (each at most 6,144 characters).
#
# THE DEDICATED POLICY IS A FIRST DRAFT for resources whose creation has not yet
# been exercised against AWS. Its first real plan is the test; expect to add an
# action or two. Managed databases are not covered yet.
#
# Each policy is built as a list of JSON statements (strings) so the four
# variants -- app and infra, shared and dedicated -- can be concatenated without
# Terraform needing their differently-shaped objects to unify. It must stay under
# IAM's 10,240 characters for a role's inline policies; policy_sizes reports it.
# ------------------------------------------------------------------------------

locals {
  dedicated = var.hosting_model == "dedicated"

  # Names the platform's own resources already use. A service called one of these
  # could otherwise generate a resource name that collides with -- and, through a
  # name-pattern permission, reach -- core's own (for example the database hub's
  # secret, or the fleet-update SSM document).
  reserved_service_names = ["database", "database-hub", "fleet", "internal", "platform", "private", "services"]

  entry_keys = [for repository, entry in var.entries : "${entry.kind}/${entry.service_name}"]

  invalid_repository_keys = [
    for repository, entry in var.entries : repository
    if !can(regex("^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$", repository))
  ]

  invalid_kinds = [
    for repository, entry in var.entries : repository
    if !contains(["app", "infra"], entry.kind)
  ]

  # Service names that cannot be used in resource names. The generated target
  # group name (<project>-<service>-<environment>-tg) is limited to 32 characters
  # by AWS.
  invalid_service_names = [
    for repository, entry in var.entries : entry.service_name
    if !can(regex("^[a-z][a-z0-9-]{1,20}[a-z0-9]$", entry.service_name))
    || length("${var.project_name}-${entry.service_name}-${var.environment}-tg") > 32
  ]

  reserved_names_used = [
    for repository, entry in var.entries : entry.service_name
    if contains(local.reserved_service_names, entry.service_name)
  ]

  entries_with_unknown_tier = [
    for repository, entry in var.entries : repository
    if !contains(keys(var.tiers), entry.tier)
  ]

  # A service's two repositories must agree on the tier they are placed in.
  tiers_by_service = {
    for name in distinct([for repository, entry in var.entries : entry.service_name]) :
    name => distinct([for repository, entry in var.entries : entry.tier if entry.service_name == name])
  }

  services_with_conflicting_tiers = [for name, tiers in local.tiers_by_service : name if length(tiers) > 1]

  has_entries = length(var.entries) > 0
  has_infra   = anytrue([for repository, entry in var.entries : entry.kind == "infra"])

  missing_inputs = local.has_entries ? concat(
    [
      for name, value in {
        assets_bucket_name = var.assets_bucket_name
        state_bucket_name  = var.state_bucket_name
      } : name if value == null
    ],
    local.dedicated ? [] : [
      for name, value in {
        deploy_bucket_name         = var.deploy_bucket_name
        fleet_update_document_name = var.fleet_update_document_name
      } : name if value == null
    ],
    local.dedicated && local.has_infra && var.permissions_boundary_arn == null ? ["permissions_boundary_arn"] : [],
  ) : []

  # Shared-fleet infra entries need the fleet's own ASG and security group.
  infra_missing_fleet_resources = local.dedicated ? [] : [
    for repository, entry in var.entries : repository
    if entry.kind == "infra" && contains(keys(var.tiers), entry.tier)
    && (try(var.tiers[entry.tier].asg_arn, null) == null || try(var.tiers[entry.tier].security_group_id, null) == null)
  ]

  ra           = "${var.aws_region}:${var.account_id}"
  iam          = "arn:aws:iam::${var.account_id}"
  boundary_arn = coalesce(var.permissions_boundary_arn, "${local.iam}:policy/platform/unset")

  # Everything each entry's policy names, computed once.
  ctx = {
    for repository, entry in var.entries : repository => {
      kind    = entry.kind
      service = entry.service_name
      tier    = entry.tier

      # <project>-<service>-<environment>: the order terraform-aws-secrets-vault
      # and terraform-aws-target-group v1 give the secret and the target group. It
      # is the ONE exception to <project>-<environment>-<service>, and goes when
      # those two modules release a v2 that follows the rule.
      service_first_prefix = "${var.project_name}-${entry.service_name}-${var.environment}"

      listener_arn = var.tiers[entry.tier].listener_arn
      rule_arns    = "${replace(var.tiers[entry.tier].listener_arn, ":listener/", ":listener-rule/")}/*"
      asg_arn      = coalesce(try(var.tiers[entry.tier].asg_arn, null), "unset")
      sg_id        = coalesce(try(var.tiers[entry.tier].security_group_id, null), "unset")

      config_bucket = "${var.project_name}-${var.environment}-${entry.service_name}-config"
    }
    if contains(keys(var.tiers), entry.tier)
  }

  # A service's infra repository can provision its database only where there is a
  # database host to provision on, which is the shared environment. A
  # dedicated environment uses a managed database, which has no container to run
  # the provisioning in; that mechanism does not exist yet.
  provisioning_enabled = !local.dedicated && var.database_provision_document_name != null && var.deploy_bucket_name != null

  # On a managed database there is no host to send a document to: the service's
  # infra repository invokes core's provisioning function instead.
  managed_provisioning_enabled = length(var.database_provision_function_arns) > 0

  deploy_bucket = coalesce(var.deploy_bucket_name, "unset")
  assets_bucket = coalesce(var.assets_bucket_name, "unset")
  state_bucket  = coalesce(var.state_bucket_name, "unset")
  fleet_doc     = coalesce(var.fleet_update_document_name, "unset")

  ##############################################################################
  # STATEMENTS -- constants
  ##############################################################################

  st_ecr_login = jsonencode({
    Sid      = "EcrLogin"
    Effect   = "Allow"
    Action   = ["ecr:GetAuthorizationToken"]
    Resource = "*"
  })

  st_lookups_app = jsonencode({
    Sid    = "ReadOnlyLookups"
    Effect = "Allow"
    Action = [
      "ec2:DescribeInstances", "ssm:DescribeInstanceInformation", "ssm:GetCommandInvocation",
      "ssm:ListCommandInvocations", "ssm:ListCommands",
    ]
    Resource = "*"
  })

  st_lookups_infra = jsonencode({
    Sid    = "ReadOnlyLookups"
    Effect = "Allow"
    Action = [
      "autoscaling:Describe*", "ec2:Describe*", "elasticloadbalancing:Describe*",
      "ssm:DescribeDocument", "ssm:DescribeParameters",
    ]
    Resource = "*"
  })

  ##############################################################################
  # STATEMENTS -- per entry
  ##############################################################################

  # ---- app: what the deploying repository does -------------------------------

  st_ecr_push = {
    for repository, c in local.ctx : repository => jsonencode({
      Sid    = "EcrPushOwnRepository"
      Effect = "Allow"
      Action = [
        "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
        "ecr:DescribeImages", "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload",
        "ecr:ListImages", "ecr:PutImage", "ecr:UploadLayerPart",
      ]
      Resource = "arn:aws:ecr:${local.ra}:repository/${c.service}/*"
    })
  }

  st_read_platform = {
    for repository, c in local.ctx : repository => jsonencode({
      Sid    = "ReadPlatformAndServiceConfig"
      Effect = "Allow"
      Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
      Resource = [
        "arn:aws:ssm:${local.ra}:parameter/${var.project_name}/platform",
        "arn:aws:ssm:${local.ra}:parameter/${var.project_name}/platform/*",
        "arn:aws:ssm:${local.ra}:parameter/${var.project_name}/database/*",
        "arn:aws:ssm:${local.ra}:parameter/${var.project_name}/services/${c.service}/*",
      ]
    })
  }

  st_static = {
    for repository, c in local.ctx : repository => [
      jsonencode({
        Sid      = "StaticAssetsOwnPrefix"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${local.assets_bucket}/static/${c.service}/*"
      }),
      jsonencode({
        Sid       = "StaticAssetsList"
        Effect    = "Allow"
        Action    = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource  = "arn:aws:s3:::${local.assets_bucket}"
        Condition = { StringLike = { "s3:prefix" = ["static/${c.service}", "static/${c.service}/*"] } }
      }),
    ]
  }

  # Publishing the compose file and env, and triggering the redeploy.
  st_app_hosting = {
    for repository, c in local.ctx : repository => local.dedicated ? [
      jsonencode({
        Sid      = "ConfigBucketPublish"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${c.config_bucket}/*"
      }),
      jsonencode({
        Sid      = "ConfigBucketList"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = "arn:aws:s3:::${c.config_bucket}"
      }),
      jsonencode({
        Sid      = "SendThisServicesUpdateDocumentOnly"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ssm:${local.ra}:document/${var.project_name}-${c.service}-update"
      }),
      jsonencode({
        Sid      = "SendOnlyToThisServicesHosts"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ec2:${local.ra}:instance/*"
        Condition = {
          StringEquals = {
            "ssm:resourceTag/Project" = var.project_name
            "ssm:resourceTag/Service" = c.service
          }
        }
      }),
      ] : [
      jsonencode({
        Sid      = "DeployBucketOwnPrefix"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${local.deploy_bucket}/${c.tier}/${c.service}/*"
      }),
      jsonencode({
        Sid       = "DeployBucketList"
        Effect    = "Allow"
        Action    = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource  = "arn:aws:s3:::${local.deploy_bucket}"
        Condition = { StringLike = { "s3:prefix" = ["${c.tier}/${c.service}", "${c.tier}/${c.service}/*"] } }
      }),
      jsonencode({
        Sid      = "SendFleetUpdateDocumentOnly"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ssm:${local.ra}:document/${local.fleet_doc}"
      }),
      jsonencode({
        Sid      = "SendOnlyToThisTiersHosts"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ec2:${local.ra}:instance/*"
        Condition = {
          StringEquals = {
            "ssm:resourceTag/Project" = var.project_name
            "ssm:resourceTag/Service" = c.tier
          }
        }
      }),
    ]
  }

  # ---- infra: what the Terraform repository does -----------------------------

  st_infra_common = {
    for repository, c in local.ctx : repository => [
      jsonencode({
        Sid    = "EcrOwnRepository"
        Effect = "Allow"
        Action = [
          "ecr:CreateRepository", "ecr:DeleteLifecyclePolicy", "ecr:DeleteRepository", "ecr:DescribeRepositories",
          "ecr:GetLifecyclePolicy", "ecr:ListTagsForResource", "ecr:PutImageScanningConfiguration",
          "ecr:PutImageTagMutability", "ecr:PutLifecyclePolicy", "ecr:TagResource", "ecr:UntagResource",
        ]
        Resource = "arn:aws:ecr:${local.ra}:repository/${c.service}/*"
      }),
      jsonencode({
        Sid      = "SecretsOwnVault"
        Effect   = "Allow"
        Action   = ["secretsmanager:*"]
        Resource = "arn:aws:secretsmanager:${local.ra}:secret:${c.service_first_prefix}-secret-vault-*"
      }),
      jsonencode({
        Sid    = "TargetGroupOwn"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags", "elasticloadbalancing:CreateTargetGroup",
          "elasticloadbalancing:DeleteTargetGroup", "elasticloadbalancing:ModifyTargetGroup",
          "elasticloadbalancing:ModifyTargetGroupAttributes", "elasticloadbalancing:RemoveTags",
        ]
        Resource = "arn:aws:elasticloadbalancing:${local.ra}:targetgroup/${c.service_first_prefix}-tg/*"
      }),
      jsonencode({
        Sid       = "ListenerRuleCreateTaggedForThisService"
        Effect    = "Allow"
        Action    = ["elasticloadbalancing:CreateRule"]
        Resource  = c.listener_arn
        Condition = { StringEquals = { "aws:RequestTag/Service" = c.service } }
      }),
      jsonencode({
        Sid      = "ListenerRuleTagOnCreate"
        Effect   = "Allow"
        Action   = ["elasticloadbalancing:AddTags"]
        Resource = c.rule_arns
        Condition = {
          StringEquals = {
            "elasticloadbalancing:CreateAction" = "CreateRule"
            "aws:RequestTag/Service"            = c.service
          }
        }
      }),
      jsonencode({
        Sid    = "ListenerRuleManageOnlyThisServicesRules"
        Effect = "Allow"
        Action = [
          "elasticloadbalancing:AddTags", "elasticloadbalancing:DeleteRule", "elasticloadbalancing:ModifyRule",
          "elasticloadbalancing:RemoveTags", "elasticloadbalancing:SetRulePriorities",
        ]
        Resource  = c.rule_arns
        Condition = { StringEquals = { "aws:ResourceTag/Service" = c.service } }
      }),
      # Every service's Terraform discovers the platform through this parameter.
      jsonencode({
        Sid      = "ReadPlatformContract"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = ["arn:aws:ssm:${local.ra}:parameter/${var.project_name}/platform", "arn:aws:ssm:${local.ra}:parameter/${var.project_name}/platform/*"]
      }),
      # The one place the two repositories meet.
      jsonencode({
        Sid    = "ServiceConfigParameter"
        Effect = "Allow"
        Action = [
          "ssm:AddTagsToResource", "ssm:DeleteParameter", "ssm:GetParameter", "ssm:GetParameters",
          "ssm:ListTagsForResource", "ssm:PutParameter", "ssm:RemoveTagsFromResource",
        ]
        Resource = "arn:aws:ssm:${local.ra}:parameter/${var.project_name}/services/${c.service}/*"
      }),
      jsonencode({
        Sid      = "StateOwnPrefix"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${local.state_bucket}/${var.state_prefix}/${c.service}/*"
      }),
      jsonencode({
        Sid       = "StateList"
        Effect    = "Allow"
        Action    = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource  = "arn:aws:s3:::${local.state_bucket}"
        Condition = { StringLike = { "s3:prefix" = ["${var.state_prefix}/${c.service}", "${var.state_prefix}/${c.service}/*"] } }
      }),
    ]
  }

  # Provisioning the service's own database: publish the request, then send the one
  # document that carries it out, and only to the database host.
  st_infra_provisioning = {
    for repository, c in local.ctx : repository => local.provisioning_enabled ? [
      jsonencode({
        Sid      = "PublishOwnProvisioningRequest"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${local.deploy_bucket}/provisioning/${c.service}/*"
      }),
      jsonencode({
        Sid      = "SendDatabaseProvisionDocumentOnly"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ssm:${local.ra}:document/${coalesce(var.database_provision_document_name, "unset")}"
      }),
      jsonencode({
        Sid      = "SendOnlyToTheDatabaseHost"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ec2:${local.ra}:instance/*"
        Condition = {
          StringEquals = {
            "ssm:resourceTag/Project" = var.project_name
            "ssm:resourceTag/Service" = var.database_service_name
          }
        }
      }),
      jsonencode({
        Sid    = "FollowItsOwnProvisioningCommand"
        Effect = "Allow"
        Action = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:ListCommands"]
        # AWS does not scope these to a command, so they are read-only by nature.
        Resource = "*"
      }),
    ] : []
  }

  # Managed database: invoke core's provisioning function, and nothing else. The
  # function derives everything from the service name it is given, so invoking it
  # for another service only re-runs that service's own provisioning.
  st_infra_managed_provisioning = {
    for repository, c in local.ctx : repository => local.managed_provisioning_enabled ? [
      jsonencode({
        Sid      = "InvokeDatabaseProvisioning"
        Effect   = "Allow"
        Action   = ["lambda:InvokeFunction"]
        Resource = var.database_provision_function_arns
      }),
    ] : []
  }

  # Shared fleet: attach to the fleet's ASG and open a port on its security group.
  st_infra_shared = {
    for repository, c in local.ctx : repository => [
      jsonencode({
        Sid    = "AttachToTierAutoScalingGroup"
        Effect = "Allow"
        Action = [
          "autoscaling:AttachLoadBalancerTargetGroups", "autoscaling:DescribeLoadBalancerTargetGroups",
          "autoscaling:DetachLoadBalancerTargetGroups",
        ]
        Resource = c.asg_arn
      }),
      jsonencode({
        Sid    = "TierSecurityGroupIngress"
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress", "ec2:ModifySecurityGroupRules", "ec2:RevokeSecurityGroupIngress",
        ]
        Resource = [
          "arn:aws:ec2:${local.ra}:security-group/${c.sg_id}",
          "arn:aws:ec2:${local.ra}:security-group-rule/*",
        ]
      }),
      jsonencode({
        Sid      = "TagSecurityGroupRules"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags", "ec2:DeleteTags"]
        Resource = "arn:aws:ec2:${local.ra}:security-group-rule/*"
      }),
    ]
  }

  # Dedicated: the service's own security group, launch template, ASG, bucket,
  # SSM document and instance role.
  st_infra_dedicated = {
    for repository, c in local.ctx : repository => [

      # --- its own security group ---------------------------------------------
      jsonencode({
        Sid      = "CreateSecurityGroupInAVpc"
        Effect   = "Allow"
        Action   = ["ec2:CreateSecurityGroup"]
        Resource = "arn:aws:ec2:${local.ra}:vpc/*"
      }),
      jsonencode({
        Sid       = "CreateSecurityGroupTaggedForThisService"
        Effect    = "Allow"
        Action    = ["ec2:CreateSecurityGroup"]
        Resource  = "arn:aws:ec2:${local.ra}:security-group/*"
        Condition = { StringEquals = { "aws:RequestTag/Service" = c.service } }
      }),
      jsonencode({
        Sid    = "ManageOwnSecurityGroups"
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupEgress", "ec2:AuthorizeSecurityGroupIngress", "ec2:DeleteSecurityGroup",
          "ec2:ModifySecurityGroupRules", "ec2:RevokeSecurityGroupEgress", "ec2:RevokeSecurityGroupIngress",
          "ec2:UpdateSecurityGroupRuleDescriptionsEgress", "ec2:UpdateSecurityGroupRuleDescriptionsIngress",
        ]
        Resource  = "arn:aws:ec2:${local.ra}:security-group/*"
        Condition = { StringEquals = { "ec2:ResourceTag/Service" = c.service } }
      }),
      jsonencode({
        Sid      = "SecurityGroupRules"
        Effect   = "Allow"
        Action   = ["ec2:ModifySecurityGroupRules", "ec2:CreateTags", "ec2:DeleteTags"]
        Resource = "arn:aws:ec2:${local.ra}:security-group-rule/*"
      }),

      # --- launch template and the instances it starts -------------------------
      jsonencode({
        Sid       = "CreateLaunchTemplateTaggedForThisService"
        Effect    = "Allow"
        Action    = ["ec2:CreateLaunchTemplate"]
        Resource  = "arn:aws:ec2:${local.ra}:launch-template/*"
        Condition = { StringEquals = { "aws:RequestTag/Service" = c.service } }
      }),
      jsonencode({
        Sid    = "ManageOwnLaunchTemplates"
        Effect = "Allow"
        Action = [
          "ec2:CreateLaunchTemplateVersion", "ec2:DeleteLaunchTemplate", "ec2:DeleteLaunchTemplateVersions",
          "ec2:ModifyLaunchTemplate",
        ]
        Resource  = "arn:aws:ec2:${local.ra}:launch-template/*"
        Condition = { StringEquals = { "ec2:ResourceTag/Service" = c.service } }
      }),
      jsonencode({
        Sid      = "TagOnCreate"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:aws:ec2:${local.ra}:*/*"
        Condition = {
          StringEquals = {
            "ec2:CreateAction"       = ["CreateLaunchTemplate", "CreateSecurityGroup", "RunInstances"]
            "aws:RequestTag/Service" = c.service
          }
        }
      }),
      # An ASG's launch template is checked against the caller's permissions.
      jsonencode({
        Sid      = "RunInstancesTaggedForThisService"
        Effect   = "Allow"
        Action   = ["ec2:RunInstances"]
        Resource = ["arn:aws:ec2:${local.ra}:instance/*", "arn:aws:ec2:${local.ra}:network-interface/*", "arn:aws:ec2:${local.ra}:volume/*"]
        Condition = {
          StringEquals = { "aws:RequestTag/Service" = c.service }
        }
      }),
      jsonencode({
        Sid    = "RunInstancesSupportingResources"
        Effect = "Allow"
        Action = ["ec2:RunInstances"]
        Resource = [
          "arn:aws:ec2:${local.ra}:image/*", "arn:aws:ec2:${local.ra}:launch-template/*",
          "arn:aws:ec2:${local.ra}:security-group/*", "arn:aws:ec2:${local.ra}:spot-instances-request/*",
          "arn:aws:ec2:${local.ra}:subnet/*",
        ]
      }),

      # --- its own auto scaling group ------------------------------------------
      jsonencode({
        Sid    = "OwnAutoScalingGroup"
        Effect = "Allow"
        Action = ["autoscaling:*"]
        # terraform-aws-autoscaling names a group <project>-<environment>-<service>-asg,
        # which is not this policy's usual <project>-<service>-<environment>
        # order. The name is the module's, so the policy follows it.
        Resource = [
          "arn:aws:autoscaling:${local.ra}:autoScalingGroup:*:autoScalingGroupName/${var.project_name}-${var.environment}-${c.service}-asg",
          "arn:aws:autoscaling:${local.ra}:scalingPolicy:*:autoScalingGroupName/${var.project_name}-${var.environment}-${c.service}-asg:policyName/*",
        ]
      }),
      jsonencode({
        Sid      = "ReadPublicAmiParameters"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${var.aws_region}::parameter/aws/service/*"
      }),

      # --- its own configuration bucket and update document --------------------
      jsonencode({
        Sid      = "OwnConfigurationBucket"
        Effect   = "Allow"
        Action   = ["s3:*"]
        Resource = ["arn:aws:s3:::${c.config_bucket}", "arn:aws:s3:::${c.config_bucket}/*"]
      }),
      jsonencode({
        Sid    = "OwnUpdateDocument"
        Effect = "Allow"
        Action = [
          "ssm:AddTagsToResource", "ssm:CreateDocument", "ssm:DeleteDocument", "ssm:DescribeDocument",
          "ssm:GetDocument", "ssm:ListTagsForResource", "ssm:RemoveTagsFromResource", "ssm:UpdateDocument",
          "ssm:UpdateDocumentDefaultVersion",
        ]
        Resource = "arn:aws:ssm:${local.ra}:document/${var.project_name}-${c.service}-*"
      }),

      # --- the instance role, capped by the permissions boundary ---------------
      jsonencode({
        Sid       = "CreateRolesOnlyWithTheBoundary"
        Effect    = "Allow"
        Action    = ["iam:CreateRole"]
        Resource  = "${local.iam}:role/services/${c.service}/*"
        Condition = { StringEquals = { "iam:PermissionsBoundary" = local.boundary_arn, "aws:RequestTag/Service" = c.service } }
      }),
      jsonencode({
        Sid       = "SetOnlyTheBoundary"
        Effect    = "Allow"
        Action    = ["iam:PutRolePermissionsBoundary"]
        Resource  = "${local.iam}:role/services/${c.service}/*"
        Condition = { StringEquals = { "iam:PermissionsBoundary" = local.boundary_arn } }
      }),
      jsonencode({
        Sid    = "ManageOwnRoles"
        Effect = "Allow"
        Action = [
          "iam:AttachRolePolicy", "iam:DeleteRole", "iam:DeleteRolePolicy", "iam:DetachRolePolicy",
          "iam:PutRolePolicy", "iam:UpdateAssumeRolePolicy", "iam:UpdateRole", "iam:UpdateRoleDescription",
        ]
        Resource = "${local.iam}:role/services/${c.service}/*"
      }),
      jsonencode({
        Sid       = "TagOwnRolesWithTheirService"
        Effect    = "Allow"
        Action    = ["iam:TagRole"]
        Resource  = "${local.iam}:role/services/${c.service}/*"
        Condition = { StringEquals = { "aws:RequestTag/Service" = c.service } }
      }),
      jsonencode({
        Sid    = "OwnPoliciesAndInstanceProfiles"
        Effect = "Allow"
        Action = [
          "iam:AddRoleToInstanceProfile", "iam:CreateInstanceProfile", "iam:CreatePolicy", "iam:CreatePolicyVersion",
          "iam:DeleteInstanceProfile", "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:RemoveRoleFromInstanceProfile",
          "iam:SetDefaultPolicyVersion", "iam:TagInstanceProfile", "iam:TagPolicy", "iam:UntagInstanceProfile",
          "iam:UntagPolicy",
        ]
        Resource = [
          "${local.iam}:instance-profile/services/${c.service}/*",
          "${local.iam}:policy/services/${c.service}/*",
        ]
      }),
      jsonencode({
        Sid       = "PassOwnRolesToEc2Only"
        Effect    = "Allow"
        Action    = ["iam:PassRole"]
        Resource  = "${local.iam}:role/services/${c.service}/*"
        Condition = { StringEquals = { "iam:PassedToService" = "ec2.amazonaws.com" } }
      }),
      jsonencode({
        Sid    = "ReadOwnIam"
        Effect = "Allow"
        Action = ["iam:Get*", "iam:List*"]
        Resource = [
          "${local.iam}:role/services/${c.service}/*",
          "${local.iam}:instance-profile/services/${c.service}/*",
          "${local.iam}:policy/services/${c.service}/*",
        ]
      }),
      jsonencode({
        Sid      = "ServiceLinkedRolesForScalingAndSpot"
        Effect   = "Allow"
        Action   = ["iam:CreateServiceLinkedRole"]
        Resource = ["${local.iam}:role/aws-service-role/autoscaling.amazonaws.com/*", "${local.iam}:role/aws-service-role/spot.amazonaws.com/*"]
        Condition = {
          StringEquals = { "iam:AWSServiceName" = ["autoscaling.amazonaws.com", "spot.amazonaws.com"] }
        }
      }),

      # --- the guard rails: these override every Allow above -------------------
      jsonencode({
        Sid      = "NeverRemoveTheBoundaryFromARole"
        Effect   = "Deny"
        Action   = ["iam:DeleteRolePermissionsBoundary"]
        Resource = "*"
      }),
      jsonencode({
        Sid       = "NeverRemoveTheServiceTag"
        Effect    = "Deny"
        Action    = ["iam:UntagRole"]
        Resource  = "*"
        Condition = { "ForAnyValue:StringEquals" = { "aws:TagKeys" = ["Service"] } }
      }),
      jsonencode({
        Sid      = "NeverChangeTheBoundaryPolicy"
        Effect   = "Deny"
        Action   = ["iam:CreatePolicyVersion", "iam:DeletePolicy", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion"]
        Resource = local.boundary_arn
      }),
    ]
  }

  ##############################################################################
  # THE FINAL POLICY -- by kind and hosting model
  ##############################################################################

  statements = {
    for repository, c in local.ctx : repository => (
      c.kind == "app"
      ? concat(
        [local.st_ecr_login, local.st_ecr_push[repository], local.st_read_platform[repository], local.st_lookups_app],
        local.st_static[repository],
        local.st_app_hosting[repository],
      )
      : concat(
        [local.st_lookups_infra],
        local.st_infra_common[repository],
        local.st_infra_provisioning[repository],
        local.st_infra_managed_provisioning[repository],
        local.dedicated ? local.st_infra_dedicated[repository] : local.st_infra_shared[repository],
      )
    )
  }

  policies = {
    for repository, statements in local.statements :
    repository => "{\"Version\":\"2012-10-17\",\"Statement\":[${join(",", statements)}]}"
  }

  # IAM allows 10,240 characters across a role's inline policies. Reaching it is a
  # real prospect: the dedicated infra policy is already over 9 KB.
  inline_policy_limit = 10240

  oversized_policies = [
    for repository, policy in local.policies : repository if length(policy) > local.inline_policy_limit
  ]
}

module "identity" {
  source   = "../identity"
  for_each = var.entries

  github_repository    = each.key
  github_owner_id      = each.value.owner_id
  github_repository_id = each.value.repository_id
  subject_format       = var.subject_format
  environment          = var.environment
}

resource "terraform_data" "service_roles_invariants" {
  lifecycle {
    precondition {
      condition     = length(local.invalid_repository_keys) == 0
      error_message = "service-roles.json keys must be OWNER/REPOSITORY. Invalid: ${join(", ", local.invalid_repository_keys)}."
    }

    precondition {
      condition     = length(local.invalid_kinds) == 0
      error_message = "Every entry needs kind \"app\" or \"infra\". Invalid: ${join(", ", local.invalid_kinds)}."
    }

    precondition {
      condition     = length(local.invalid_service_names) == 0
      error_message = "service_name must be 3-22 lowercase letters, digits or hyphens, starting with a letter, and short enough that ${var.project_name}-<service>-${var.environment}-tg fits AWS's 32-character target group name limit. Invalid: ${join(", ", local.invalid_service_names)}."
    }

    precondition {
      condition     = length(local.reserved_names_used) == 0
      error_message = "These service names are reserved because the platform's own resources use them (${join(", ", local.reserved_service_names)}): ${join(", ", local.reserved_names_used)}."
    }

    precondition {
      condition     = length(distinct(local.entry_keys)) == length(local.entry_keys)
      error_message = "A service may have at most one \"app\" and one \"infra\" entry. Two entries share a kind and a service_name."
    }

    precondition {
      condition     = length(local.services_with_conflicting_tiers) == 0
      error_message = "A service's app and infra entries must name the same tier. Conflicting: ${join(", ", local.services_with_conflicting_tiers)}."
    }

    precondition {
      condition     = length(local.entries_with_unknown_tier) == 0
      error_message = "These entries name a tier that does not exist in this environment: ${join(", ", local.entries_with_unknown_tier)}. Available tiers: ${join(", ", keys(var.tiers))}."
    }

    precondition {
      condition     = length(local.missing_inputs) == 0
      error_message = "service-roles.json has entries, so these inputs are required but not set: ${join(", ", local.missing_inputs)}."
    }

    precondition {
      condition     = length(local.oversized_policies) == 0
      error_message = "These generated policies exceed IAM's ${local.inline_policy_limit}-character limit for a role's inline policies: ${join(", ", local.oversized_policies)}. Split them into managed policies (6,144 characters each) rather than trimming what a role legitimately needs."
    }

    precondition {
      condition     = length(local.infra_missing_fleet_resources) == 0
      error_message = "Shared-fleet hosting needs each tier's asg_arn and security_group_id. Missing for: ${join(", ", local.infra_missing_fleet_resources)}."
    }
  }
}

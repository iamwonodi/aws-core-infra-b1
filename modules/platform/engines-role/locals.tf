locals {
  enabled = var.repository != null

  missing_inputs = local.enabled ? [
    for name, value in {
      deploy_bucket_name            = var.deploy_bucket_name
      isolated_security_group_id    = var.isolated_security_group_id
      database_update_document_name = var.database_update_document_name
      state_bucket_name             = var.state_bucket_name
    } : name if value == null
  ] : []

  arn_region_account = "${var.aws_region}:${var.account_id}"

  policy = local.enabled && length(local.missing_inputs) == 0 ? jsonencode({
    Version = "2012-10-17"
    Statement = [

      # --- What the platforms team publishes ---------------------------------
      {
        Sid      = "PublishEngineDefinitions"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${coalesce(var.deploy_bucket_name, "unset")}/database/*"
      },
      {
        Sid      = "ListEngineDefinitions"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = "arn:aws:s3:::${coalesce(var.deploy_bucket_name, "unset")}"
        Condition = {
          StringLike = { "s3:prefix" = ["database", "database/*"] }
        }
      },

      # --- Applying them: one document, on the database host only --------------
      {
        Sid      = "SendDatabaseUpdateDocumentOnly"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ssm:${local.arn_region_account}:document/${coalesce(var.database_update_document_name, "unset")}"
      },
      {
        Sid      = "SendOnlyToTheDatabaseHost"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:aws:ec2:${local.arn_region_account}:instance/*"
        Condition = {
          StringEquals = {
            "ssm:resourceTag/Project" = var.project_name
            "ssm:resourceTag/Service" = var.database_service_name
          }
        }
      },

      # --- Reading the platform contract ---------------------------------------
      # The pipeline learns the bucket, the update document and the security
      # groups from the contract, never from core's state.
      {
        Sid      = "ReadPlatformContract"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:aws:ssm:${local.arn_region_account}:parameter/${var.project_name}/platform/config"
      },

      # --- Publishing each engine's port for services to read -----------------
      {
        Sid    = "EnginePortParameters"
        Effect = "Allow"
        Action = [
          "ssm:AddTagsToResource", "ssm:DeleteParameter", "ssm:GetParameter", "ssm:GetParameters",
          "ssm:ListTagsForResource", "ssm:PutParameter", "ssm:RemoveTagsFromResource",
        ]
        Resource = "arn:aws:ssm:${local.arn_region_account}:parameter/${var.project_name}/database/engines/*"
      },

      # --- Opening each engine's port on the isolated tier --------------------
      {
        Sid    = "IsolatedSecurityGroupIngress"
        Effect = "Allow"
        Action = [
          "ec2:AuthorizeSecurityGroupIngress", "ec2:ModifySecurityGroupRules", "ec2:RevokeSecurityGroupIngress",
        ]
        Resource = [
          "arn:aws:ec2:${local.arn_region_account}:security-group/${coalesce(var.isolated_security_group_id, "unset")}",
          "arn:aws:ec2:${local.arn_region_account}:security-group-rule/*",
        ]
      },
      {
        Sid      = "TagSecurityGroupRules"
        Effect   = "Allow"
        Action   = ["ec2:CreateTags", "ec2:DeleteTags"]
        Resource = "arn:aws:ec2:${local.arn_region_account}:security-group-rule/*"
      },

      # --- Engine images, mirrored into ECR under one prefix ------------------
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrEngineImages"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:CompleteLayerUpload",
          "ecr:CreateRepository", "ecr:DescribeImages", "ecr:DescribeRepositories",
          "ecr:GetDownloadUrlForLayer", "ecr:InitiateLayerUpload", "ecr:ListImages",
          "ecr:ListTagsForResource", "ecr:PutImage", "ecr:TagResource", "ecr:UploadLayerPart",
        ]
        Resource = "arn:aws:ecr:${local.arn_region_account}:repository/${var.image_repository_prefix}/*"
      },

      # --- Read-only lookups (AWS cannot scope these to one resource) ---------
      {
        Sid    = "ReadOnlyLookups"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances", "ec2:DescribeSecurityGroupRules", "ec2:DescribeSecurityGroups",
          "ec2:DescribeTags", "ssm:DescribeInstanceInformation", "ssm:DescribeParameters",
          "ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:ListCommands",
        ]
        Resource = "*"
      },

      # --- Its own Terraform state --------------------------------------------
      {
        Sid      = "StateOwnPrefix"
        Effect   = "Allow"
        Action   = ["s3:DeleteObject", "s3:GetObject", "s3:PutObject"]
        Resource = "arn:aws:s3:::${coalesce(var.state_bucket_name, "unset")}/${var.state_prefix}/*"
      },
      {
        Sid      = "StateList"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = "arn:aws:s3:::${coalesce(var.state_bucket_name, "unset")}"
        Condition = {
          StringLike = { "s3:prefix" = [var.state_prefix, "${var.state_prefix}/*"] }
        }
      },
    ]
  }) : null
}

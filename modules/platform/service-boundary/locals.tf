# ------------------------------------------------------------------------------
# SERVICE PERMISSIONS BOUNDARY
#
# In staging and production a service's infrastructure repository creates its own
# hosts, which means it creates an IAM role for them (the instance role). A role
# that can create roles could otherwise create one more powerful than itself, so
# the infrastructure role may only create roles that carry THIS boundary. A
# boundary is a ceiling: whatever policies are later attached to such a role, its
# effective permissions are the intersection with this policy. Even
# AdministratorAccess attached to a service's instance role grants nothing beyond
# what is listed here.
#
# The boundary names no service. It uses the policy variable ${aws:PrincipalTag/Service}:
# every role a service creates must be tagged Service=<service> (the infrastructure
# role's policy requires it, and forbids removing the tag), so the same policy
# confines each service's instance role to its OWN secret, bucket, image repository
# and parameters.
#
# WHAT IT ALLOWS: what a host needs to run a service and nothing else --
# the SSM agent (so deploys can reach it), pulling its own images, reading its own
# secret, its own configuration bucket, and the platform's published parameters.
# WHAT IT DENIES: all of IAM and STS role assumption, so an instance role cannot
# widen its own reach or pivot to another role.
# ------------------------------------------------------------------------------

locals {
  policy_name = "${var.project_name}-service-boundary"

  # A dedicated path keeps the boundary out of the namespace services may create
  # policies in (/services/<service>/), so no service-controlled name can ever
  # match it.
  policy_path = "/platform/"

  ra  = "${var.aws_region}:${var.account_id}"
  tag = "$${aws:PrincipalTag/Service}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SsmAgent"
        Effect = "Allow"
        Action = [
          "ec2messages:AcknowledgeMessage", "ec2messages:DeleteMessage", "ec2messages:FailMessage",
          "ec2messages:GetEndpoint", "ec2messages:GetMessages", "ec2messages:SendReply",
          "ssm:DescribeDocument", "ssm:GetDocument", "ssm:GetManifest", "ssm:ListAssociations",
          "ssm:ListInstanceAssociations", "ssm:PutComplianceItems", "ssm:PutConfigurePackageResult",
          "ssm:PutInventory", "ssm:UpdateAssociationStatus", "ssm:UpdateInstanceAssociationStatus",
          "ssm:UpdateInstanceInformation", "ssmmessages:CreateControlChannel", "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel", "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid      = "PullOwnImages"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = "arn:aws:ecr:${local.ra}:repository/${local.tag}/*"
      },
      {
        Sid      = "ReadOwnSecret"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = "arn:aws:secretsmanager:${local.ra}:secret:${var.project_name}-${local.tag}-${var.environment}-secret-vault-*"
      },
      {
        Sid      = "ReadOwnConfigurationBucket"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.project_name}-${var.environment}-${local.tag}-config/*"
      },
      {
        Sid      = "ListOwnConfigurationBucket"
        Effect   = "Allow"
        Action   = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.project_name}-${var.environment}-${local.tag}-config"
      },
      # Core owns the deploy library and the deploy engine, so a fix is one
      # upload rather than one per service repository. A host therefore reads
      # them from core's bucket -- only the reserved prefix, never a directory
      # belonging to another service.
      {
        Sid      = "ReadPlatformScripts"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${coalesce(var.deploy_bucket_name, "unset")}/_platform/*"
      },
      {
        Sid       = "ListPlatformScripts"
        Effect    = "Allow"
        Action    = ["s3:GetBucketLocation", "s3:ListBucket"]
        Resource  = "arn:aws:s3:::${coalesce(var.deploy_bucket_name, "unset")}"
        Condition = { StringLike = { "s3:prefix" = ["_platform", "_platform/*"] } }
      },
      {
        Sid    = "ReadPublishedParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = [
          "arn:aws:ssm:${local.ra}:parameter/${var.project_name}/platform/*",
          "arn:aws:ssm:${local.ra}:parameter/${var.project_name}/services/${local.tag}/*",

          # The manifest a host verifies the platform scripts against.
          "arn:aws:ssm:${local.ra}:parameter/${var.project_name}/platform/scripts-manifest",
        ]
      },
      {
        Sid      = "NoIamAndNoRoleAssumption"
        Effect   = "Deny"
        Action   = ["iam:*", "sts:AssumeRole", "sts:AssumeRoleWithWebIdentity", "sts:AssumeRoleWithSAML"]
        Resource = "*"
      },
    ]
  })
}

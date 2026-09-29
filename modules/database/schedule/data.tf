data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    # Only this account's schedules may use the role.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

# DocumentDB's management API is authorised through the rds: actions.
data "aws_iam_policy_document" "permissions" {
  dynamic "statement" {
    for_each = length(var.instances) > 0 ? [1] : []

    content {
      sid       = "StartAndStopInstances"
      actions   = ["rds:StartDBInstance", "rds:StopDBInstance"]
      resources = [for instance in var.instances : instance.arn]
    }
  }

  dynamic "statement" {
    for_each = length(var.clusters) > 0 ? [1] : []

    content {
      sid       = "StartAndStopClusters"
      actions   = ["rds:StartDBCluster", "rds:StopDBCluster"]
      resources = [for cluster in var.clusters : cluster.arn]
    }
  }
}

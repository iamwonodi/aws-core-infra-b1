# ------------------------------------------------------------------------------
# DATABASE SCHEDULE
#
# Starts RDS instances and DocumentDB clusters on the chosen days at a set time and
# stops them again, to
# pay only for the hours an environment is used. Storage and backups are billed
# either way; only the instance-hours stop.
#
#   start   on each running day, at start
#   stop    EVERY day, at stop. Daily rather than on the running days only, so
#           an instance someone started by hand, or one AWS restarted by itself
#           (it does after 7 days stopped), is stopped again that evening.
#
# EventBridge Scheduler calls RDS and DocumentDB directly (no Lambda). A
# DocumentDB cluster stops as a whole, so it is started and stopped through its
# cluster, not its instances. Starting what is already running, or stopping what
# is already stopped, is refused and harmlessly logged as a failed invocation;
# nothing is retried.
#
# While the instances are stopped, services cannot reach their databases: their
# deploys fail health checks and their provisioning fails. That is the trade.
# ------------------------------------------------------------------------------

locals {
  start = split(":", var.start)
  stop  = split(":", var.stop)

  # Minutes since midnight, to compare the two times.
  start_minutes = tonumber(local.start[0]) * 60 + tonumber(local.start[1])
  stop_minutes  = tonumber(local.stop[0]) * 60 + tonumber(local.stop[1])

  start_expression = "cron(${tonumber(local.start[1])} ${tonumber(local.start[0])} ? * ${join(",", var.days)} *)"
  stop_expression  = "cron(${tonumber(local.stop[1])} ${tonumber(local.stop[0])} * * ? *)"

  # What to call for each kind of target, and the input naming it.
  targets = merge(
    { for engine, instance in var.instances : engine => { kind = "instance", id = instance.id, arn = instance.arn } },
    { for engine, cluster in var.clusters : engine => { kind = "cluster", id = cluster.id, arn = cluster.arn } },
  )

  api = {
    instance = { service = "rds", start = "startDBInstance", stop = "stopDBInstance", key = "DBInstanceIdentifier" }
    cluster  = { service = "docdb", start = "startDBCluster", stop = "stopDBCluster", key = "DBClusterIdentifier" }
  }

  schedules = merge(
    {
      for engine, target in local.targets : "${engine}-start" => {
        target     = "arn:aws:scheduler:::aws-sdk:${local.api[target.kind].service}:${local.api[target.kind].start}"
        input      = jsonencode({ (local.api[target.kind].key) = target.id })
        expression = local.start_expression
        purpose    = "Starts the ${engine} ${target.kind} on ${join(", ", var.days)} at ${var.start} ${var.timezone}."
      }
    },
    {
      for engine, target in local.targets : "${engine}-stop" => {
        target     = "arn:aws:scheduler:::aws-sdk:${local.api[target.kind].service}:${local.api[target.kind].stop}"
        input      = jsonencode({ (local.api[target.kind].key) = target.id })
        expression = local.stop_expression
        purpose    = "Stops the ${engine} ${target.kind} every day at ${var.stop} ${var.timezone}."
      }
    },
  )
}

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

resource "aws_iam_role" "this" {
  name               = "${var.project_name}-${var.environment}-database-schedule"
  description        = "Lets EventBridge Scheduler start and stop this environment's databases."
  assume_role_policy = data.aws_iam_policy_document.trust.json

  tags = var.tags
}

resource "aws_iam_role_policy" "this" {
  name   = "start-and-stop"
  role   = aws_iam_role.this.id
  policy = data.aws_iam_policy_document.permissions.json
}

resource "aws_scheduler_schedule" "this" {
  for_each = local.schedules

  name        = "${var.project_name}-${var.environment}-${each.key}"
  description = each.value.purpose

  schedule_expression          = each.value.expression
  schedule_expression_timezone = var.timezone

  flexible_time_window {
    mode = "OFF"
  }

  target {
    arn      = each.value.target
    role_arn = aws_iam_role.this.arn
    input    = each.value.input

    # A refusal (already running, already stopped) will not succeed on retry.
    retry_policy {
      maximum_retry_attempts = 0
    }
  }

  depends_on = [aws_iam_role_policy.this]
}

resource "terraform_data" "invariants" {
  lifecycle {
    precondition {
      condition     = local.start_minutes < local.stop_minutes
      error_message = "start (${var.start}) must be earlier than stop (${var.stop}): the instances run within one day."
    }

    precondition {
      condition     = length(var.instances) + length(var.clusters) > 0
      error_message = "There are no instances or clusters to schedule."
    }

    precondition {
      condition     = length(setintersection(keys(var.instances), keys(var.clusters))) == 0
      error_message = "An engine is listed as both an instance and a cluster."
    }
  }
}

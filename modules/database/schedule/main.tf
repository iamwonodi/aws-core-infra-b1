# ------------------------------------------------------------------------------
# DATABASE SCHEDULE
#
# Starts RDS instances on the chosen days at a set time and stops them again, to
# pay only for the hours an environment is used. Storage and backups are billed
# either way; only the instance-hours stop.
#
#   start   on each running day, at start
#   stop    EVERY day, at stop. Daily rather than on the running days only, so
#           an instance someone started by hand, or one AWS restarted by itself
#           (it does after 7 days stopped), is stopped again that evening.
#
# EventBridge Scheduler calls RDS directly (no Lambda). Starting an instance
# that is already running, or stopping one that is already stopped, is refused
# by RDS and harmlessly logged as a failed invocation; nothing is retried.
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

  schedules = merge(
    {
      for engine, instance in var.instances : "${engine}-start" => {
        instance   = instance
        action     = "startDBInstance"
        expression = "cron(${tonumber(local.start[1])} ${tonumber(local.start[0])} ? * ${join(",", var.days)} *)"
        purpose    = "Starts the ${engine} instance on ${join(", ", var.days)} at ${var.start} ${var.timezone}."
      }
    },
    {
      for engine, instance in var.instances : "${engine}-stop" => {
        instance   = instance
        action     = "stopDBInstance"
        expression = "cron(${tonumber(local.stop[1])} ${tonumber(local.stop[0])} * * ? *)"
        purpose    = "Stops the ${engine} instance every day at ${var.stop} ${var.timezone}."
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

data "aws_iam_policy_document" "permissions" {
  statement {
    actions   = ["rds:StartDBInstance", "rds:StopDBInstance"]
    resources = [for instance in var.instances : instance.arn]
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.project_name}-${var.environment}-database-schedule"
  description        = "Lets EventBridge Scheduler start and stop this environment's database instances."
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
    arn      = "arn:aws:scheduler:::aws-sdk:rds:${each.value.action}"
    role_arn = aws_iam_role.this.arn
    input    = jsonencode({ DBInstanceIdentifier = each.value.instance.id })

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
      condition     = length(var.instances) > 0
      error_message = "There are no instances to schedule."
    }
  }
}

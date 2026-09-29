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

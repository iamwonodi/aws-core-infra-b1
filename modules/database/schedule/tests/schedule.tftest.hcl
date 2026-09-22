# Run with: terraform init -backend=false && terraform test   (no AWS access needed)

mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/acme-staging-database-schedule" }
  }
}

variables {
  project_name = "acme"
  environment  = "staging"
  instances = {
    postgres = { id = "acme-staging-postgres", arn = "arn:aws:rds:af-south-1:123456789012:db:acme-staging-postgres" }
    mysql    = { id = "acme-staging-mysql", arn = "arn:aws:rds:af-south-1:123456789012:db:acme-staging-mysql" }
  }
}

run "defaults_run_weekends_eight_to_seven_lagos" {
  command = plan

  assert {
    condition     = aws_scheduler_schedule.this["postgres-start"].schedule_expression == "cron(0 8 ? * SAT,SUN *)"
    error_message = "starts on weekends at 08:00"
  }

  assert {
    condition     = aws_scheduler_schedule.this["postgres-stop"].schedule_expression == "cron(0 19 * * ? *)"
    error_message = "stops EVERY day at 19:00, so a manual or AWS restart is stopped that evening"
  }

  assert {
    condition     = alltrue([for s in aws_scheduler_schedule.this : s.schedule_expression_timezone == "Africa/Lagos"])
    error_message = "times are Lagos time"
  }
}

run "each_instance_gets_its_own_start_and_stop" {
  command = plan

  assert {
    condition     = toset(keys(aws_scheduler_schedule.this)) == toset(["postgres-start", "postgres-stop", "mysql-start", "mysql-stop"])
    error_message = "one start and one stop per instance"
  }

  assert {
    condition     = aws_scheduler_schedule.this["mysql-start"].target[0].arn == "arn:aws:scheduler:::aws-sdk:rds:startDBInstance" && aws_scheduler_schedule.this["mysql-stop"].target[0].arn == "arn:aws:scheduler:::aws-sdk:rds:stopDBInstance"
    error_message = "the schedules call RDS directly"
  }

  assert {
    condition     = jsondecode(aws_scheduler_schedule.this["mysql-stop"].target[0].input).DBInstanceIdentifier == "acme-staging-mysql"
    error_message = "each schedule names its own instance"
  }

  assert {
    condition     = aws_scheduler_schedule.this["postgres-start"].name == "acme-staging-postgres-start"
    error_message = "schedules follow <project>-<environment>-<resource>"
  }
}

run "a_custom_window" {
  command = plan

  variables {
    days     = ["MON", "WED", "FRI"]
    start    = "07:30"
    stop     = "21:45"
    timezone = "Europe/London"
  }

  assert {
    condition     = aws_scheduler_schedule.this["postgres-start"].schedule_expression == "cron(30 7 ? * MON,WED,FRI *)" && aws_scheduler_schedule.this["postgres-stop"].schedule_expression == "cron(45 21 * * ? *)"
    error_message = "the window is the caller's"
  }
}

run "stop_before_start_is_refused" {
  command = plan

  variables {
    start = "19:00"
    stop  = "08:00"
  }

  expect_failures = [terraform_data.invariants]
}

run "an_unknown_day_is_refused" {
  command = plan

  variables {
    days = ["SATURDAY"]
  }

  expect_failures = [var.days]
}

run "a_malformed_time_is_refused" {
  command = plan

  variables {
    start = "8am"
  }

  expect_failures = [var.start]
}

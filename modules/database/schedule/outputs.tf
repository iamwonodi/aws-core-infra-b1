output "schedule_names" {
  description = "The start and stop schedules, keyed <engine>-start and <engine>-stop."
  value       = { for key, schedule in aws_scheduler_schedule.this : key => schedule.name }
}

output "role_arn" {
  description = "Role the schedules act as."
  value       = aws_iam_role.this.arn
}

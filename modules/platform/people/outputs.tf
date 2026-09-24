output "usernames" {
  description = "Each person's database user, by name: platform.<name>."
  value       = local.usernames
}

output "access" {
  description = "Each person's access level, by database user: \"read\" or \"write\"."
  value       = { for name, person in var.people : local.usernames[name] => person.access }
}

output "secret_arn" {
  description = "The secret holding every person's database password and access level, keyed by database user. Provisioning reads it; an empty one means nobody."
  value       = aws_secretsmanager_secret.this.arn
}

output "emails" {
  description = "Every person's email, in lower case: the platform list's declaration to the front door."
  value       = sort([for person in values(var.people) : lower(person.email)])
}

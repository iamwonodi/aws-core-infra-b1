output "usernames" {
  description = "Each person's database user, by name: agent_<name>."
  value       = local.usernames
}

output "access" {
  description = "Each person's access level, by database user: \"read\" or \"write\"."
  value       = { for name, person in var.people : local.usernames[name] => person.access }
}

output "secret_arn" {
  description = "The secret holding every person's database password, keyed by database user. Null while nobody is listed."
  value       = length(module.secret) > 0 ? module.secret[0].secret_arn : null
}

output "front_door" {
  description = "The Cognito user pool the team tools' web addresses sit behind, and its sign-in domain prefix. Null where there is no front door."
  value = var.front_door ? {
    user_pool_id  = aws_cognito_user_pool.this[0].id
    user_pool_arn = aws_cognito_user_pool.this[0].arn
    domain        = aws_cognito_user_pool_domain.this[0].domain
  } : null
}

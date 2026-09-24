output "front_door" {
  description = "The user pool the team tools' web addresses sit behind, its sign-in domain prefix, and where services declare their agents' emails (front-door/<service>.json in the deploy bucket)."
  value = {
    user_pool_id       = aws_cognito_user_pool.this.id
    user_pool_arn      = aws_cognito_user_pool.this.arn
    domain             = aws_cognito_user_pool_domain.this.domain
    declaration_prefix = local.declaration_prefix
  }
}

output "function_name" {
  description = "The function that makes the pool's users match the declarations."
  value       = aws_lambda_function.this.function_name
}

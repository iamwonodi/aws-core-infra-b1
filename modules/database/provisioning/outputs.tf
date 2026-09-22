output "function_name" {
  description = "The provisioning function's name."
  value       = aws_lambda_function.this.function_name
}

output "function_arn" {
  description = "ARN of the function. A service's infrastructure role is granted lambda:InvokeFunction on exactly this."
  value       = aws_lambda_function.this.arn
}

output "security_group_id" {
  description = "The function's own security group, which the database's ingress rule names."
  value       = aws_security_group.this.id
}

output "role_arn" {
  description = "ARN of the role the function runs as."
  value       = aws_iam_role.this.arn
}

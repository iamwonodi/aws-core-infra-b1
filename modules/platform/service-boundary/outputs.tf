output "policy_name" {
  description = "Name of the boundary policy."
  value       = local.policy_name
}

output "policy_path" {
  description = "IAM path of the boundary policy."
  value       = local.policy_path
}

output "policy_json" {
  description = "The boundary policy document."
  value       = local.policy
}

output "policy_arn" {
  description = "ARN the boundary will have once created. Service infrastructure roles may only create roles that carry exactly this boundary."
  value       = "arn:aws:iam::${var.account_id}:policy${local.policy_path}${local.policy_name}"
}

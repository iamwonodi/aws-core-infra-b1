output "parameter_name" {
  description = "Name of the SSM parameter the contract is published under."
  value       = local.parameter_name
}

output "config_json" {
  description = "The contract, as JSON."
  value       = local.config_json

  depends_on = [terraform_data.contract_invariants]
}

output "schema_version" {
  description = "Version of the contract's shape."
  value       = local.schema_version
}

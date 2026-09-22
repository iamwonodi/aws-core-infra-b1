output "service_roles" {
  description = "Input for the OIDC module's service_roles: for each repository (a service's app and infra repositories each get their own), the token subjects to trust and the generated scoped policy."

  value = {
    for repository, entry in var.entries : repository => {
      policy_arns   = []
      oidc_subjects = module.identity[repository].oidc_subjects
      description   = coalesce(entry.description, "CI role for the ${entry.service_name} service's ${entry.kind} repository (${entry.tier} tier) in ${var.environment}.")

      inline_policies = {
        "service-${entry.kind}-access" = local.policies[repository]
      }

      # The subjects above already embed the IDs; the OIDC module must not
      # derive a second set from them.
      owner_id      = null
      repository_id = null
    }
  }

  depends_on = [terraform_data.service_roles_invariants]
}

output "policy_sizes" {
  description = "Length in characters of each generated policy. IAM allows a role at most 10,240 characters of inline policy."
  value       = { for repository, policy in local.policies : repository => length(policy) }
}

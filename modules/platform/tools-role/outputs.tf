output "service_roles" {
  description = "Input for the OIDC module's service_roles, to merge with the service roles. Empty when no repository is set."

  value = local.enabled ? {
    (var.repository.name) = {
      policy_arns   = []
      oidc_subjects = module.identity[0].oidc_subjects
      description   = "CI role for the team-tools repository in ${var.environment}."

      inline_policies = {
        "team-tools-access" = local.policy
      }

      owner_id      = null
      repository_id = null
    }
  } : {}

  depends_on = [terraform_data.tools_role_invariants]
}

output "policy_size" {
  description = "Length in characters of the generated policy (IAM allows 10,240 for a role's inline policies). Null when no repository is set."
  value       = local.policy == null ? null : length(local.policy)
}

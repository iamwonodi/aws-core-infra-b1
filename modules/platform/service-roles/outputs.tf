output "service_roles" {
  description = "Input for the OIDC module's service_roles: for each repository (a service's app and infra repositories each get their own), the token subjects to trust and the generated scoped policy."

  value = {
    for repository, entry in var.entries : repository => {
      # The role's permissions: managed policies under /platform/service-roles/,
      # which the role itself cannot change.
      policy_arns = [
        for key, policy in local.managed_policies : local.managed_policy_arns[key] if policy.repository == repository
      ]
      oidc_subjects = module.identity[repository].oidc_subjects
      description   = coalesce(entry.description, "CI role for the ${entry.service_name} service's ${entry.kind} repository (${entry.tier} tier) in ${var.environment}.")

      inline_policies = {}

      # The subjects above already embed the IDs; the OIDC module must not
      # derive a second set from them.
      owner_id      = null
      repository_id = null
    }
  }

  # The ARNs above are built, not read from the policies, so this makes the roles
  # wait for the policies to exist before attaching them.
  depends_on = [terraform_data.service_roles_invariants, aws_iam_policy.service]
}

output "policy_sizes" {
  description = "For each repository, the length in characters of each of its managed policies, in order. IAM allows 6,144 per managed policy."
  value       = { for repository, chunks in local.policy_chunks : repository => [for document in chunks : length(document)] }
}

output "policies" {
  description = "For each repository, all of its role's permissions as one policy document, for review. What IAM receives is the same statements split into managed policies."
  value       = local.policies
}

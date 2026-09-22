output "identifier" {
  description = "The repository as it appears in an OIDC subject: OWNER@ID/REPO@ID in the immutable format, OWNER/REPO in the classic one."
  value       = local.identifier
}

output "oidc_subjects" {
  description = "Token subjects to trust: the environment, and the environment's -plan companion."
  value       = local.oidc_subjects
}

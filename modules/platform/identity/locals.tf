locals {
  owner_name      = split("/", var.github_repository)[0]
  repository_name = split("/", var.github_repository)[1]

  identifier = (
    var.subject_format == "immutable"
    ? "${local.owner_name}@${coalesce(var.github_owner_id, "unset")}/${local.repository_name}@${coalesce(var.github_repository_id, "unset")}"
    : var.github_repository
  )

  environments = [var.environment, "${var.environment}-plan"]

  oidc_subjects = [for name in local.environments : "repo:${local.identifier}:environment:${name}"]
}

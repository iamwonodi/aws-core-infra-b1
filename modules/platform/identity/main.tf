# ------------------------------------------------------------------------------
# GITHUB IDENTITY
#
# Turns a repository and environment into the OIDC token subjects AWS should
# trust. It creates no infrastructure; terraform_data only hosts a precondition
# so a misconfiguration stops the plan.
#
# Every job that touches AWS declares a GitHub Environment, and GitHub then
# issues its token with an environment subject
# (repo:OWNER/REPO:environment:NAME) instead of a branch or pull-request
# subject. The default subjects of the OIDC module therefore never match these
# workflows.
#
# Two environments are trusted per stage: <env> for the job that changes the
# live environment, and <env>-plan for plan jobs. Keeping them separate lets
# GitHub protect them differently -- <env> can be restricted to main and require
# reviewers, while plans on pull requests use <env>-plan.
#
# The IMMUTABLE format embeds the numeric owner and repository IDs, so a
# renamed or transferred repository cannot be impersonated by someone who later
# claims the old name. Repositories created, renamed or transferred on or after
# 15 July 2026 emit it.
# ------------------------------------------------------------------------------

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

resource "terraform_data" "identity_invariants" {
  lifecycle {
    precondition {
      condition = (
        var.subject_format != "immutable" || (
          var.github_owner_id != null && var.github_repository_id != null &&
          can(regex("^[0-9]+$", coalesce(var.github_owner_id, "x"))) &&
          can(regex("^[0-9]+$", coalesce(var.github_repository_id, "x")))
        )
      )

      error_message = "subject_format \"immutable\" needs the numeric github_owner_id and github_repository_id of ${var.github_repository}. Read them with: gh api repos/${var.github_repository} --jq '[.owner.id, .id]'"
    }
  }
}

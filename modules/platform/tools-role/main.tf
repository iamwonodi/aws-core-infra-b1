# ------------------------------------------------------------------------------
# TEAM TOOLS ROLE
#
# The team's own tools (the database GUIs, later others) are run by their own
# repository. Core makes room for them (the team-tools security group, the front
# door, database access); that repository runs them: their hosts, schedules and
# web addresses. This module generates the role its pipeline assumes, scoped to
# exactly that, the way engines-role does for the platforms team.
#
# Everything the repository creates is tagged Service=team-tools, and its IAM
# lives under /services/team-tools/ with core's permissions boundary, whose
# ${aws:PrincipalTag/Service} confines the tools' instance role to the SSM agent
# and team-tools' own names. "team-tools" is a reserved service name, so no
# service can ever share the tag.
#
# It grants nothing until a repository is set.
#
# WHAT AWS CANNOT SCOPE: creating an app client on the user pool cannot be
# limited to some clients. A client alone admits no one (sign-ins come only from
# the front door's declarations), but it is why this repository's changes need
# review.
# ------------------------------------------------------------------------------

module "identity" {
  source = "../identity"
  count  = local.enabled ? 1 : 0

  github_repository    = var.repository.name
  github_owner_id      = var.repository.owner_id
  github_repository_id = var.repository.repository_id
  subject_format       = var.subject_format
  environment          = var.environment
}

resource "terraform_data" "tools_role_invariants" {
  lifecycle {
    precondition {
      condition     = length(local.missing_inputs) == 0
      error_message = "A team-tools repository is set, so these inputs are required but not set: ${join(", ", local.missing_inputs)}."
    }

    # IAM allows 10,240 characters across a role's inline policies.
    precondition {
      condition     = local.policy == null ? true : length(local.policy) <= 10240
      error_message = "The team-tools policy is ${local.policy == null ? 0 : length(local.policy)} characters, over IAM's 10,240 for a role's inline policies."
    }
  }
}

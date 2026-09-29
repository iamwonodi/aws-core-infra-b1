# ------------------------------------------------------------------------------
# DATABASE ENGINES ROLE
#
# The platforms team owns the database engines: they publish a compose file per
# engine and a registry to the deploy bucket, then trigger the database host to
# apply them. Their pipeline also opens each engine's port on the
# isolated security group and publishes that port for services to read. This
# module generates the role that pipeline assumes, scoped to exactly that.
#
# It grants nothing until a repository is set.
#
# WHAT AWS CANNOT SCOPE. The isolated security group is where the databases
# live, and IAM cannot limit which port or source a rule opens: this role can
# change any inbound rule on it. That is the platforms team's job, but it is why
# changes to that repository need review as careful as core's.
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

resource "terraform_data" "engines_role_invariants" {
  lifecycle {
    precondition {
      condition     = length(local.missing_inputs) == 0
      error_message = "A database engines repository is set, so these inputs are required but not set: ${join(", ", local.missing_inputs)}."
    }
  }
}

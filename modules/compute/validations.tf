# ------------------------------------------------------------------------------
# COMPUTE INVARIANTS
#
# Enforced as resource preconditions rather than check blocks: a failed check
# only prints a warning and the plan carries on, whereas a failed precondition
# stops it. terraform_data is only a home for the preconditions and manages no
# infrastructure.
# ------------------------------------------------------------------------------

resource "terraform_data" "compute_invariants" {
  lifecycle {
    precondition {
      condition = (
        var.private_fleet_min_size <= var.private_fleet_desired_capacity &&
        var.private_fleet_desired_capacity <= var.private_fleet_max_size
      )

      error_message = "private_fleet capacity values must satisfy min <= desired <= max (got min ${var.private_fleet_min_size}, desired ${var.private_fleet_desired_capacity}, max ${var.private_fleet_max_size})."
    }

    precondition {
      condition = (
        var.internal_fleet_min_size <= var.internal_fleet_desired_capacity &&
        var.internal_fleet_desired_capacity <= var.internal_fleet_max_size
      )

      error_message = "internal_fleet capacity values must satisfy min <= desired <= max (got min ${var.internal_fleet_min_size}, desired ${var.internal_fleet_desired_capacity}, max ${var.internal_fleet_max_size})."
    }
  }
}

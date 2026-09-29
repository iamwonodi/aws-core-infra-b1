# ------------------------------------------------------------------------------
# NETWORK INVARIANTS
#
# These are enforced as resource preconditions, not check blocks. A failed
# check block only prints a warning and the plan carries on, so a wrong summary
# CIDR would still reach AWS -- and the NACL rules are built from those summary
# CIDRs, so a wrong one silently blocks a tier's traffic or lets another
# tier's traffic in. A failed precondition stops the plan with an error.
#
# terraform_data is used only as a home for the preconditions; it manages no
# infrastructure and needs no provider.
#
# Containment is tested without cidrcontains() (Terraform 1.8+) so the module
# keeps working on Terraform 1.6: a CIDR "inner" sits inside "outer" when
# outer's prefix is no more specific than inner's and inner's network address,
# masked to outer's prefix length, equals outer's network address.
# ------------------------------------------------------------------------------

resource "terraform_data" "network_invariants" {
  lifecycle {
    precondition {
      condition     = local.vpc_prefix_length >= 16 && local.vpc_prefix_length <= 28
      error_message = "vpc_cidr must have a prefix length between /16 and /28, the range AWS allows for a VPC."
    }

    precondition {
      condition     = local.vpc_in_private_space
      error_message = "vpc_cidr must sit inside private address space (10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16 or 100.64.0.0/10). A public range would make real internet hosts unreachable from inside the VPC."
    }

    precondition {
      condition     = length(local.summaries_outside_vpc) == 0
      error_message = "Every summary CIDR must lie inside vpc_cidr. Outside the VPC: ${join(", ", local.summaries_outside_vpc)}."
    }

    precondition {
      condition     = length(local.subnets_outside_summary) == 0
      error_message = "Every subnet CIDR must lie inside its tier's summary CIDR, because the NACL rules are built from the summaries. Outside: ${join(", ", local.subnets_outside_summary)}."
    }

    precondition {
      condition     = length(local.overlapping_summaries) == 0
      error_message = "Tier summary CIDRs must not overlap, or one tier's NACL rules would apply to another tier's subnets. Overlapping: ${join(", ", local.overlapping_summaries)}."
    }
  }
}

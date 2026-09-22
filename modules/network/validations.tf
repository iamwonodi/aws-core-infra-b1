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

locals {
  # Address space a VPC may safely use. Public ranges are excluded: the VPC
  # would claim addresses that belong to real hosts on the internet.
  private_address_ranges = [
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "100.64.0.0/10",
  ]

  tier_cidrs = {
    public   = { summary = var.public_summary_cidr, subnets = var.public_subnet_cidrs }
    private  = { summary = var.private_summary_cidr, subnets = var.private_subnet_cidrs }
    internal = { summary = var.internal_summary_cidr, subnets = var.internal_subnet_cidrs }
    isolated = { summary = var.isolated_summary_cidr, subnets = var.isolated_subnet_cidrs }
  }

  vpc_prefix_length = tonumber(split("/", var.vpc_cidr)[1])

  vpc_in_private_space = anytrue([
    for range in local.private_address_ranges :
    tonumber(split("/", range)[1]) <= local.vpc_prefix_length &&
    cidrhost("${cidrhost(var.vpc_cidr, 0)}/${split("/", range)[1]}", 0) == cidrhost(range, 0)
  ])

  # "tier subnet" strings for every subnet that lies outside its tier's summary.
  subnets_outside_summary = flatten([
    for tier, cfg in local.tier_cidrs : [
      for subnet in cfg.subnets : "${tier} ${subnet}"
      if !(
        tonumber(split("/", cfg.summary)[1]) <= tonumber(split("/", subnet)[1]) &&
        cidrhost("${cidrhost(subnet, 0)}/${split("/", cfg.summary)[1]}", 0) == cidrhost(cfg.summary, 0)
      )
    ]
  ])

  # Tiers whose summary lies outside the VPC.
  summaries_outside_vpc = [
    for tier, cfg in local.tier_cidrs : "${tier} ${cfg.summary}"
    if !(
      local.vpc_prefix_length <= tonumber(split("/", cfg.summary)[1]) &&
      cidrhost("${cidrhost(cfg.summary, 0)}/${local.vpc_prefix_length}", 0) == cidrhost(var.vpc_cidr, 0)
    )
  ]

  # Every unordered pair of tiers whose summaries overlap. Two CIDRs overlap
  # exactly when the less specific one contains the other's network address.
  tier_names = sort(keys(local.tier_cidrs))

  overlapping_summaries = flatten([
    for i, a in local.tier_names : [
      for j, b in local.tier_names : "${a} and ${b}"
      if i < j && (
        cidrhost("${cidrhost(local.tier_cidrs[a].summary, 0)}/${min(tonumber(split("/", local.tier_cidrs[a].summary)[1]), tonumber(split("/", local.tier_cidrs[b].summary)[1]))}", 0) ==
        cidrhost("${cidrhost(local.tier_cidrs[b].summary, 0)}/${min(tonumber(split("/", local.tier_cidrs[a].summary)[1]), tonumber(split("/", local.tier_cidrs[b].summary)[1]))}", 0)
      )
    ]
  ])
}

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

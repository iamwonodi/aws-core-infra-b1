locals {
  all_network = "0.0.0.0/0"

  public_sg_name        = "public-tier"
  public_sg_description = "Security group for public-tier infrastructure such as application load balancers and public gateway resources."

  private_sg_name        = "private-tier"
  private_sg_description = "Security group for frontend applications and publicly accessible APIs in private subnets."

  internal_sg_name        = "internal-tier"
  internal_sg_description = "Security group for backend application services and internal workloads in internal subnets."

  tools_sg_name        = "team-tools"
  tools_sg_description = "Worn by the team tools (database GUIs and the like), which run in private subnets on their own hosts."

  isolated_sg_name        = "isolated-tier"
  isolated_sg_description = "Security group for isolated database workloads with no default internet access."

  endpoint_sg_name        = "vpc-endpoint"
  endpoint_sg_description = "Security group for VPC endpoints which provides private connectivity to the AWS service."

  # The required public entry points for the load balancer.
  endpoint_ingress_ports = [443]

  # Every tier whose hosts call AWS services, and the team's tools, which run on
  # hosts of their own. The public tier runs none.
  # The VPC endpoints use private DNS, so every instance in the VPC reaches
  # these services through them, the NAT instance included (Session Manager is
  # its only way in). The NAT's key depends only on nat_type, known at plan time.
  endpoint_client_security_groups = merge(
    {
      private  = module.private_sg.id
      internal = module.internal_sg.id
      isolated = module.isolated_sg.id
      tools    = module.tools_sg.id
    },
    var.nat_type == "instance" ? { nat = module.nat_instance[0].security_group_id } : {}
  )
}

# ------------------------------------------------------------------------------
# NETWORK INVARIANT VALUES
#
# What the preconditions in validations.tf check, built from variables only.
# tests/run.sh copies this section alone -- from this banner to the block's
# closing brace -- with variables.tf and validations.tf, and tests the
# invariants without AWS. Keep it free of module and resource references.
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

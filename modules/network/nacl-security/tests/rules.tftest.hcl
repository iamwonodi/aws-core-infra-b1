# The network ACL rules in locals.tf, checked without AWS. Run by run.sh
# against variables.tf and locals.tf only.

variables {
  vpc_id              = "vpc-0123456789abcdef0"
  project_name        = "example"
  environment         = "development"
  public_subnet_ids   = ["subnet-00000000000000001"]
  private_subnet_ids  = ["subnet-00000000000000002"]
  internal_subnet_ids = ["subnet-00000000000000003"]
  isolated_subnet_ids = ["subnet-00000000000000004"]
  public_cidr_block   = "10.10.0.0/20"
  private_cidr_block  = "10.10.16.0/20"
  internal_cidr_block = "10.10.32.0/20"
  isolated_cidr_block = "10.10.48.0/20"
}

run "rules" {
  command = plan

  # The module takes map(object(...)), which silently drops any attribute it
  # does not know: a rule written inside another rule would vanish unseen.
  assert {
    condition = alltrue(flatten([
      for tier, rules in local.rules : [
        for name, rule in rules :
        length(setsubtract(keys(rule), ["rule_number", "protocol", "rule_action", "cidr_block", "from_port", "to_port", "icmp_type", "icmp_code"])) == 0
      ]
    ]))
    error_message = "A rule has an attribute a network ACL rule does not have: probably another rule nested inside it."
  }

  assert {
    condition = alltrue([
      for tier, rules in local.rules :
      length(distinct([for rule in values(rules) : rule.rule_number])) == length(rules)
    ])
    error_message = "Two rules in one tier and direction share a rule number."
  }

  # Through the NAT, a packet keeps the internet host's address: requests go to
  # 0.0.0.0/0 and replies come from it, never from the public subnets.
  assert {
    condition = alltrue([
      for tier in ["private", "internal"] :
      anytrue([for rule in values(local.rules["${tier}_egress"]) : rule.cidr_block == "0.0.0.0/0" && rule.from_port <= 443 && rule.to_port >= 443])
    ])
    error_message = "The private and internal tiers must be able to send HTTPS to the internet (through the NAT)."
  }

  assert {
    condition = alltrue([
      for tier in ["private", "internal"] :
      anytrue([for rule in values(local.rules["${tier}_ingress"]) : rule.cidr_block == "0.0.0.0/0" && rule.from_port <= 1024 && rule.to_port >= 65535])
    ])
    error_message = "The private and internal tiers must accept replies from the internet on ephemeral ports."
  }

  assert {
    condition = (
      anytrue([for rule in values(local.rules.isolated_ingress) : rule.cidr_block == var.public_cidr_block && rule.from_port <= 443 && rule.to_port >= 443]) &&
      anytrue([for rule in values(local.rules.isolated_egress) : rule.cidr_block == var.public_cidr_block && rule.from_port <= 1024 && rule.to_port >= 65535])
    )
    error_message = "The NAT instance (public tier) must reach the VPC endpoints in the isolated tier and hear back."
  }
}

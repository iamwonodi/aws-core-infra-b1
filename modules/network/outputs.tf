output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc_base.vpc_id
}

output "public_subnet_ids" {
  description = "Public tier subnet IDs."
  value       = module.vpc_base.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private tier subnet IDs."
  value       = module.vpc_base.private_subnet_ids
}

output "internal_subnet_ids" {
  description = "Internal tier subnet IDs."
  value       = module.vpc_base.internal_subnet_ids
}

# The same subnets, handed out only once their route to the internet exists: the
# NAT, the route tables through it, the NACLs and the tier's outbound rule. For
# whatever reaches the internet the moment it starts: the golden image build
# fetches Image Builder's bootstrap at once, and failed when the rebuild started
# it a few seconds before the NAT. depends_on sits on this output, not on the
# consumer's module, so nothing the consumer reads is put off until the apply.
output "internal_egress_subnet_ids" {
  description = "Internal tier subnet IDs, available once their route to the internet (NAT, route tables, NACLs, outbound rule) exists."
  value       = module.vpc_base.internal_subnet_ids

  depends_on = [
    module.nat_gateway,
    module.nat_instance,
    module.route_tables,
    module.nacl_security,
    module.global_outbound_routing,
  ]
}

output "isolated_subnet_ids" {
  description = "Isolated tier subnet IDs."
  value       = module.vpc_base.isolated_subnet_ids
}

output "public_security_group_id" {
  description = "Security group ID for the public tier."
  value       = module.public_sg.id
}

output "private_security_group_id" {
  description = "Security group ID for the private tier."
  value       = module.private_sg.id
}

output "internal_security_group_id" {
  description = "Security group ID for the internal tier."
  value       = module.internal_sg.id
}

output "isolated_security_group_id" {
  description = "Security group ID for the isolated tier."
  value       = module.isolated_sg.id
}

output "tools_security_group_id" {
  description = "Security group worn by the team's own tools. The databases and the VPC endpoints admit it."
  value       = module.tools_sg.id
}

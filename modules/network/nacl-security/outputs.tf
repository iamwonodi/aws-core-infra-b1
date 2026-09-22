output "network_acl_ids" {
  description = "Network ACL IDs for each subnet tier."
  value       = module.nacl_security.network_acl_ids
}

output "public_network_acl_id" {
  description = "Network ACL ID associated with the public tier."
  value       = module.nacl_security.public_network_acl_id
}

output "private_network_acl_id" {
  description = "Network ACL ID associated with the private tier."
  value       = module.nacl_security.private_network_acl_id
}

output "internal_network_acl_id" {
  description = "Network ACL ID associated with the internal tier."
  value       = module.nacl_security.internal_network_acl_id
}

output "isolated_network_acl_id" {
  description = "Network ACL ID associated with the isolated tier."
  value       = module.nacl_security.isolated_network_acl_id
}
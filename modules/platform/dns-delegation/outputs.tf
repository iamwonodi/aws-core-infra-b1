output "id" {
  description = "ID of the reusable delegation set, for the public zone's delegation_set_id."
  value       = aws_route53_delegation_set.this.id
}

output "name_servers" {
  description = "The four name servers to set as the domain's NS records at the registrar."
  value       = aws_route53_delegation_set.this.name_servers
}

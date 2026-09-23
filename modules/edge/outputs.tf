output "private_zone_id" {
  description = "ID of the private Route 53 hosted zone. Consumed by the database domain module for the database's IAM Route 53 permissions and its private DNS registration."
  value       = module.route53.zone_ids["private"]
}

output "distribution_id" {
  description = "ID of the CloudFront distribution."
  value       = module.cloudfront.id
}

output "distribution_domain_name" {
  description = "CloudFront-generated distribution domain name."
  value       = module.cloudfront.domain_name
}

output "assets_bucket_id" {
  description = "ID of the S3 bucket assets are uploaded to."
  value       = module.assets_bucket.bucket_id
}

output "assets_bucket_arn" {
  description = "ARN of the S3 bucket assets are uploaded to."
  value       = module.assets_bucket.bucket_arn
}

output "private_alb_https_listener_arn" {
  description = "ARN of the private-tier ALB's HTTPS listener (port 443)."
  value       = module.private_alb.https_listener_arn
  sensitive   = true
}

output "internal_alb_https_listener_arn" {
  description = "ARN of the internal-tier ALB's HTTPS listener (port 443). Null while internal_tier_enabled is off."
  value       = try(module.internal_alb[0].https_listener_arn, null)
  sensitive   = true
}

output "private_alb_security_group_id" {
  description = "Security group of the private-tier ALB. A service allows this group to reach its service port."
  value       = module.private_alb_sg.security_group_id
}

output "internal_alb_security_group_id" {
  description = "Security group of the internal-tier ALB. A service allows this group to reach its service port. Null while internal_tier_enabled is off."
  value       = try(module.internal_alb_sg[0].security_group_id, null)
}

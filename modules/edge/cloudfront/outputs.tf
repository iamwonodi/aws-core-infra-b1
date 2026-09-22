################################################################################
# TERRAFORM AWS CLOUDFRONT MODULE
# COMPLETE EXAMPLE OUTPUTS
################################################################################


################################################################################
# CLOUDFRONT DISTRIBUTION
################################################################################

output "id" {
  description = "ID of the CloudFront distribution."
  value       = module.cloudfront.id
}


output "arn" {
  description = "ARN of the CloudFront distribution."
  value       = module.cloudfront.arn
}


output "domain_name" {
  description = "CloudFront-generated distribution domain name."
  value       = module.cloudfront.domain_name
}


output "hosted_zone_id" {
  description = "Route 53 hosted zone ID associated with the CloudFront distribution."
  value       = module.cloudfront.hosted_zone_id
}


output "status" {
  description = "Current deployment status of the CloudFront distribution."
  value       = module.cloudfront.status
}


output "header" {
  description = "The custom HTTP header name used by CloudFront for alb origin verification."
  value       = local.cloudfront_header
}


output "token" {
  description = "The secret token injected by CloudFront in the alb origin custom HTTP header to authenticate requests."
  value       = local.cloudfront_token
  sensitive   = true
}


################################################################################
# AUTOMATIC S3 ORIGIN ACCESS CONTROL
################################################################################

output "s3_oac_id" {
  description = "ID of the Origin Access Control automatically created by the CloudFront module."
  value       = module.cloudfront.s3_oac_id
}


output "s3_oac_arn" {
  description = "ARN of the Origin Access Control automatically created by the CloudFront module."
  value       = module.cloudfront.s3_oac_arn
}


################################################################################
# STANDARD LOGGING V2
################################################################################

output "logging_delivery_source_arn" {
  description = "ARN of the CloudFront Standard Logging v2 delivery source."
  value       = module.cloudfront.logging_delivery_source_arn
}


output "logging_delivery_destination_arn" {
  description = "ARN of the CloudFront Standard Logging v2 delivery destination."
  value       = module.cloudfront.logging_delivery_destination_arn
}
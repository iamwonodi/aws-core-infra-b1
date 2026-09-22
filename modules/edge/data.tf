# -----------------------------------------------------------------------------
# CloudFront Origin-Facing Prefix List
# -----------------------------------------------------------------------------
# Retrieves the AWS-managed prefix list containing CloudFront's
# origin-facing IP ranges. Used to restrict the private-tier ALB's security
# group to CloudFront traffic only.
#
# AWS's own guidance confirms this same prefix-list-based restriction
# remains the correct approach even for a VPC origin (see main.tf's
# aws_cloudfront_vpc_origin resource) -- it is not specific to custom
# origins.
# -----------------------------------------------------------------------------

data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

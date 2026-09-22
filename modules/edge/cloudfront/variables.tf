################################################################################
# TERRAFORM AWS CLOUDFRONT MODULE
# COMPLETE EXAMPLE VARIABLES
################################################################################


################################################################################
# GENERAL CONFIGURATION
################################################################################

variable "project_name" {
  description = "Project name used by the CloudFront module for resource naming and tagging."
  type        = string

  validation {
    condition     = trimspace(var.project_name) != ""
    error_message = "project_name must not be empty."
  }
}


variable "environment" {
  description = "Deployment environment."
  type        = string

  validation {
    condition     = trimspace(var.environment) != ""
    error_message = "environment must not be empty."
  }
}


variable "comment" {
  description = "Description assigned to the CloudFront distribution."
  type        = string

  default = "CloudFront distribution"

  validation {
    condition     = trimspace(var.comment) != ""
    error_message = "comment must not be empty."
  }
}


################################################################################
# S3 ORIGIN
################################################################################

variable "s3_bucket_id" {
  description = "ID/name of the externally managed private S3 bucket used by CloudFront."
  type        = string

  validation {
    condition     = trimspace(var.s3_bucket_id) != ""
    error_message = "s3_bucket_id must not be empty."
  }
}


variable "s3_bucket_arn" {
  description = "ARN of the externally managed private S3 bucket used by CloudFront."
  type        = string

  validation {
    condition     = can(regex("^arn:aws[a-zA-Z-]*:s3:::[^/]+$", var.s3_bucket_arn))
    error_message = "s3_bucket_arn must be a valid S3 bucket ARN."
  }
}


variable "s3_origin_domain_name" {
  description = "Regional S3 bucket domain name used as the CloudFront S3 origin."
  type        = string

  validation {
    condition     = trimspace(var.s3_origin_domain_name) != ""
    error_message = "s3_origin_domain_name must not be empty."
  }
}


################################################################################
# APPLICATION ORIGIN
################################################################################

variable "alb_origin_domain_name" {
  description = "DNS name of the externally managed Application Load Balancer used as the alb origin."
  type        = string

  validation {
    condition     = trimspace(var.alb_origin_domain_name) != ""
    error_message = "alb_origin_domain_name must not be empty."
  }
}

variable "alb_vpc_origin_id" {
  description = "ID of the aws_cloudfront_vpc_origin pointed at the ALB. The ALB is internal (not internet-facing), so CloudFront must reach it through a VPC origin rather than a plain custom origin, which requires the origin to be reachable over the public internet."
  type        = string

  validation {
    condition     = trimspace(var.alb_vpc_origin_id) != ""
    error_message = "alb_vpc_origin_id must not be empty."
  }
}


################################################################################
# CUSTOM DOMAIN / ACM
################################################################################

variable "aliases" {
  description = "Custom domain names associated with the CloudFront distribution."
  type        = list(string)

  default = []

  validation {
    condition     = length(distinct(var.aliases)) == length(var.aliases)
    error_message = "aliases must contain unique domain names."
  }
}


variable "acm_certificate_arn" {
  description = "ARN of the ACM certificate used by CloudFront. The certificate must be provisioned in us-east-1."
  type        = string

  default = null

  validation {
    condition = (
      var.acm_certificate_arn == null ||
      can(regex("^arn:aws[a-zA-Z-]*:acm:[a-z0-9-]+:[0-9]{12}:certificate/[a-f0-9-]+$", var.acm_certificate_arn))
    )

    error_message = "acm_certificate_arn must be a valid ACM certificate ARN or null."
  }
}


################################################################################
# AWS WAF
################################################################################

variable "web_acl_id" {
  description = "Optional ARN of an externally managed AWS WAF Web ACL."
  type        = string

  default = null

  validation {
    condition = (
      var.web_acl_id == null ||
      can(regex("^arn:aws[a-zA-Z-]*:wafv2:[a-z0-9-]+:[0-9]{12}:global/webacl/.+$", var.web_acl_id))
    )

    error_message = "web_acl_id must be a valid global AWS WAFv2 Web ACL ARN or null."
  }
}


################################################################################
# STANDARD LOGGING V2
################################################################################

variable "logging_enabled" {
  description = "Whether CloudFront Standard Logging v2 should be enabled."
  type        = bool

  default = false
}


variable "logging_source_name" {
  description = "Name of the CloudFront Standard Logging v2 delivery source."
  type        = string

  default = "cloudfront-access-logs-source"

  validation {
    condition     = trimspace(var.logging_source_name) != ""
    error_message = "logging_source_name must not be empty."
  }
}


variable "logging_destination_name" {
  description = "Name of the CloudFront Standard Logging v2 delivery destination."
  type        = string

  default = "cloudfront-access-logs-destination"

  validation {
    condition     = trimspace(var.logging_destination_name) != ""
    error_message = "logging_destination_name must not be empty."
  }
}


variable "logging_destination_type" {
  description = "Type of the externally managed Standard Logging v2 destination."
  type        = string

  default = "s3"

  validation {
    condition = contains(
      [
        "s3",
        "cloudwatch_logs",
        "firehose"
      ],
      var.logging_destination_type
    )

    error_message = "logging_destination_type must be one of: s3, cloudwatch_logs, firehose."
  }
}


variable "logging_destination_arn" {
  description = "ARN of the externally managed Standard Logging v2 destination."
  type        = string

  default = null

  validation {
    condition = (
      var.logging_destination_arn == null ||
      trimspace(var.logging_destination_arn) != ""
    )

    error_message = "logging_destination_arn must not be an empty string."
  }
}


variable "logging_region" {
  description = "AWS region used by the Standard Logging v2 delivery resources."
  type        = string

  default = "us-east-1"

  validation {
    condition     = can(regex("^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$", var.logging_region))
    error_message = "logging_region must be a valid AWS region."
  }
}


################################################################################
# TAGS
################################################################################

variable "tags" {
  description = "Additional tags applied to CloudFront and supported resources."
  type        = map(string)

  default = {}
}
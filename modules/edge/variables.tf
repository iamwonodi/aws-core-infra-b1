################################################################################
# CORE IDENTIFICATION
################################################################################

variable "project_name" {
  type        = string
  description = "Project name used to identify every resource this module creates."

  validation {
    condition     = trimspace(var.project_name) != ""
    error_message = "project_name must not be empty."
  }
}

variable "environment" {
  type        = string
  description = "Deployment environment used to identify every resource this module creates."

  validation {
    condition     = trimspace(var.environment) != ""
    error_message = "environment must not be empty."
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region this environment's resources are deployed into. Used for the default (non-CloudFront) ACM certificate's region, since CloudFront's own certificate is always issued in us-east-1 regardless of this value."

  validation {
    condition     = trimspace(var.aws_region) != ""
    error_message = "aws_region must not be empty."
  }
}

################################################################################
# NETWORK PLACEMENT
#
# Supplied by the network domain module's outputs -- this module owns no
# networking resources of its own.
################################################################################

variable "vpc_id" {
  type        = string
  description = "VPC ID. Used to associate the private Route 53 hosted zone with this VPC."

  validation {
    condition     = trimspace(var.vpc_id) != ""
    error_message = "vpc_id must not be empty."
  }
}

variable "private_subnet_ids" {
  type        = list(string)
  description = "Private-tier subnet IDs. The private-tier ALB is placed here."

  validation {
    condition     = length(var.private_subnet_ids) > 0
    error_message = "private_subnet_ids must contain at least one subnet ID."
  }
}

variable "internal_subnet_ids" {
  type        = list(string)
  description = "Internal-tier subnet IDs. The internal-tier ALB is placed here."

  validation {
    condition     = length(var.internal_subnet_ids) > 0
    error_message = "internal_subnet_ids must contain at least one subnet ID."
  }
}

variable "private_security_group_id" {
  type        = string
  description = "Security group ID for the private tier. The internal-tier ALB allows inbound traffic from this security group, since the private tier's backend API is what calls the internal tier."

  validation {
    condition     = trimspace(var.private_security_group_id) != ""
    error_message = "private_security_group_id must not be empty."
  }
}

################################################################################
# DNS
################################################################################

variable "domain_name" {
  type        = string
  description = "Public-facing domain name. Used for the public Route 53 hosted zone, the public-facing ACM certificates, and CloudFront's aliases."

  validation {
    condition     = trimspace(var.domain_name) != ""
    error_message = "domain_name must not be empty."
  }
}

variable "private_domain" {
  type        = string
  description = "Domain name used for internal, VPC-only DNS resolution. May be the same value as domain_name -- the private Route 53 hosted zone is keyed by a logical label, not by this domain name, so a public and a private zone sharing the identical domain name (split-horizon DNS) is fully supported, not a conflict."

  validation {
    condition     = trimspace(var.private_domain) != ""
    error_message = "private_domain must not be empty."
  }
}

################################################################################
# S3 ASSETS BUCKET
################################################################################

variable "assets_path" {
  type        = string
  description = "Local path to the checked-out assets directory uploaded to the assets bucket and served through CloudFront."

  validation {
    condition     = trimspace(var.assets_path) != ""
    error_message = "assets_path must not be empty."
  }
}

variable "assets_force_destroy" {
  type        = bool
  description = "Whether the assets bucket can be destroyed while it still contains objects. See this module's README for why this is deliberately different across environments."
  default     = false
}

variable "assets_noncurrent_version_expiration_days" {
  type        = number
  description = "Days after which a noncurrent object version in the assets bucket expires. See this module's README for why this is deliberately different across environments."
  default     = 90

  validation {
    condition     = var.assets_noncurrent_version_expiration_days >= 1
    error_message = "assets_noncurrent_version_expiration_days must be at least 1."
  }
}

variable "internal_tier_enabled" {
  type        = bool
  default     = false
  description = "Create the internal-tier load balancer (with its security group and the private DNS wildcard pointing at it). Off until an internal-tier service needs it."
}

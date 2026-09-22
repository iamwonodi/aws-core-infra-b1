variable "project_name" {
  type        = string
  description = "Project name."
}

variable "environment" {
  type        = string
  description = "Environment name."
}

variable "deploy_bucket_name" {
  type        = string
  default     = null
  description = "Core's deploy bucket. A service's hosts read the platform scripts core publishes under its _platform/ prefix, and nothing else in it. Null leaves that out of the boundary."
}

variable "aws_region" {
  type        = string
  description = "AWS Region the boundary applies to."
}

variable "account_id" {
  type        = string
  description = "AWS account ID the boundary applies to."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

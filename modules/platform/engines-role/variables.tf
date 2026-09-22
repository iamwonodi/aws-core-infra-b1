variable "project_name" {
  type        = string
  description = "Project name."
}

variable "environment" {
  type        = string
  description = "Environment name."
}

variable "aws_region" {
  type        = string
  description = "AWS Region the permissions apply to."
}

variable "account_id" {
  type        = string
  description = "AWS account ID the permissions apply to."

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account ID."
  }
}

variable "subject_format" {
  type        = string
  default     = "immutable"
  description = "OIDC subject format GitHub emits for the repository: \"immutable\" (numeric IDs) or \"classic\"."
}

variable "repository" {
  type = object({
    name          = string
    owner_id      = optional(string)
    repository_id = optional(string)
  })
  default     = null
  description = "The platforms team's repository (OWNER/REPOSITORY), which publishes the database engines. Null grants nothing."
}

variable "deploy_bucket_name" {
  type        = string
  default     = null
  description = "Fleet deploy bucket, where the engine definitions are published under database/. Required when repository is set."
}

variable "isolated_security_group_id" {
  type        = string
  default     = null
  description = "Security group of the isolated tier, on which each engine opens its own port. Required when repository is set."
}

variable "database_update_document_name" {
  type        = string
  default     = null
  description = "SSM document that makes the database host apply the published engines. Required when repository is set."
}

variable "database_service_name" {
  type        = string
  default     = "database-hub"
  description = "Value of the Service tag on the database host. The update document may only be sent to instances carrying it."
}

variable "state_bucket_name" {
  type        = string
  default     = null
  description = "Terraform state bucket. Required when repository is set."
}

variable "state_prefix" {
  type        = string
  default     = "platform/database-engines"
  description = "Key prefix, inside the state bucket, under which the platforms repository keeps its Terraform state."
}

variable "image_repository_prefix" {
  type        = string
  default     = "engines"
  description = "ECR repository prefix under which the platforms repository may create and push engine images. The database host has no internet path, so engine images must be mirrored into ECR."
}
